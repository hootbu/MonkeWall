import AppKit
import AVFoundation

private final class ImageBox: @unchecked Sendable {
    var image: CGImage?
}

/// Registers the current video as a native macOS "aerial" wallpaper choice and
/// points the lock screen (Idle wallpaper) at it. This is the same mechanism
/// Apple uses for its own aerial videos, so the lock screen keeps playing the
/// video even when this app is not running.
final class AerialsManager {
    static let shared = AerialsManager()

    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private let assetID = "4B4799A5-6C82-47A2-89A5-06622F38EFDA"
    private let categoryID = "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
    private let subcategoryID = "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E"
    private let displayName = "MonkeWall"
    private let thumbnailQueue = DispatchQueue(label: "com.hootbu.monkewall.thumbnail", qos: .utility)

    private var backupDirectory: URL {
        supportDirectory.appendingPathComponent("backup", isDirectory: true)
    }
    private var storeBackupURL: URL {
        backupDirectory.appendingPathComponent("Index.plist.original")
    }
    private var aerialsRoot: URL {
        home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }
    private var videosDirectory: URL {
        aerialsRoot.appendingPathComponent("videos", isDirectory: true)
    }
    private var thumbnailsDirectory: URL {
        aerialsRoot.appendingPathComponent("thumbnails", isDirectory: true)
    }
    private var entriesURL: URL {
        aerialsRoot.appendingPathComponent("manifest/entries.json")
    }
    private var storeURL: URL {
        home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }
    private var installedVideoURL: URL {
        videosDirectory.appendingPathComponent("\(assetID).mov")
    }
    private var thumbnailURL: URL {
        thumbnailsDirectory.appendingPathComponent("\(assetID).png")
    }
    private var cacheDirectory: URL {
        home.appendingPathComponent(
            "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.aerials",
            isDirectory: true
        )
    }

    private init() {}

    // MARK: - Public

    func isInstalled() -> Bool {
        guard fileManager.fileExists(atPath: installedVideoURL.path) else { return false }
        guard currentIdleAssetID() == assetID else { return false }
        return entriesContainAsset()
    }

    @discardableResult
    func install(videoURL: URL, force: Bool = false, select: Bool = true) -> Bool {
        guard fileManager.fileExists(atPath: videoURL.path) else {
            appLog("Aerials: source video missing at \(videoURL.path)")
            return false
        }

        do {
            try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: entriesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            backupCurrentSelection()

            let sourceSize = fileSize(videoURL)
            let installedSize = fileSize(installedVideoURL)
            let videoChanged = force
                || sourceSize != installedSize
                || !fileManager.fileExists(atPath: installedVideoURL.path)

            if videoChanged {
                if fileManager.fileExists(atPath: installedVideoURL.path) {
                    try fileManager.removeItem(at: installedVideoURL)
                }
                try fileManager.copyItem(at: videoURL, to: installedVideoURL)
                thumbnailQueue.async {
                    self.generateThumbnail(from: videoURL, to: self.thumbnailURL)
                }
                appLog("Aerials: video copied (\(sourceSize) bytes)")
            }

            guard updateEntries() else { return false }

            let alreadySelected = currentIdleAssetID() == assetID
                && currentDesktopAssetID() == assetID
            let shouldSelect = select && !alreadySelected
            if shouldSelect {
                guard updateStore() else { return false }
            }

            if videoChanged || shouldSelect {
                restartWallpaperAgent()
            }

            appLog("Aerials: installed (changed=\(videoChanged), selected=\(alreadySelected))")
            return true
        } catch {
            appLog("Aerials: install failed: \(error)")
            return false
        }
    }

    func waitForThumbnail() {
        thumbnailQueue.sync {}
    }

    @discardableResult
    func refresh() -> Bool {
        guard fileManager.fileExists(atPath: installedVideoURL.path) else {
            appLog("Aerials: refresh skipped, asset missing")
            return false
        }

        if !entriesContainAsset() {
            _ = updateEntries()
        }

        guard currentIdleAssetID() == assetID || currentDesktopAssetID() == assetID else {
            return true
        }

        restartWallpaperAgent()
        appLog("Aerials: refreshed")
        return true
    }

    @discardableResult
    func remove() -> Bool {
        let idleWasOurs = currentIdleAssetID() == assetID
        let desktopWasOurs = currentDesktopAssetID() == assetID

        if idleWasOurs || desktopWasOurs {
            restoreWallpaperFromBackup()
        }

        let stillInUse = currentIdleAssetID() == assetID || currentDesktopAssetID() == assetID
        if !stillInUse {
            removeFromEntries()
            try? fileManager.removeItem(at: installedVideoURL)
            try? fileManager.removeItem(at: thumbnailURL)
        }

        restartWallpaperAgent()
        appLog("Aerials: removed (idleWasOurs=\(idleWasOurs), desktopWasOurs=\(desktopWasOurs), stillInUse=\(stillInUse))")
        return !stillInUse
    }

    // MARK: - Backups

    private func loadBackup() -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeBackupURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) else { return nil }
        return plist as? [String: Any]
    }

    private func backupCurrentSelection() {
        try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        guard let store = loadStore() else { return }

        var backup = loadBackup() ?? store
        for scopeKey in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard let scope = store[scopeKey] as? [String: Any] else { continue }
            var backupScope = backup[scopeKey] as? [String: Any] ?? [:]
            for partKey in ["Desktop", "Idle"] where assetID(from: scope, key: partKey) != assetID {
                backupScope[partKey] = scope[partKey]
            }
            backup[scopeKey] = backupScope
        }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: backup, format: .binary, options: 0
            )
            try data.write(to: storeBackupURL, options: .atomic)
        } catch {
            appLog("Aerials: could not back up wallpaper store: \(error)")
        }
    }

    private func restoreWallpaperFromBackup() {
        guard let backup = loadBackup(), var store = loadStore() else {
            appLog("Aerials: no usable wallpaper-store backup")
            return
        }

        var restored = false
        for scopeKey in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard var scope = store[scopeKey] as? [String: Any],
                  let backupScope = backup[scopeKey] as? [String: Any] else { continue }

            var restoredPart = false
            for partKey in ["Desktop", "Idle"] {
                if assetID(from: scope, key: partKey) == assetID,
                   let backupPart = backupScope[partKey] {
                    scope[partKey] = backupPart
                    restoredPart = true
                }
            }
            if restoredPart {
                store[scopeKey] = scope
                restored = true
            }
        }

        guard restored else { return }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: store, format: .binary, options: 0
            )
            try data.write(to: storeURL, options: .atomic)
            appLog("Aerials: previous wallpaper settings restored")
        } catch {
            appLog("Aerials: restore failed: \(error)")
        }
    }

    // MARK: - entries.json

    private func readEntries() -> [String: Any]? {
        guard let data = try? Data(contentsOf: entriesURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private func entriesContainAsset() -> Bool {
        guard let entries = readEntries(),
              let assets = entries["assets"] as? [[String: Any]] else { return false }
        return assets.contains { ($0["id"] as? String) == assetID }
    }

    private func updateEntries() -> Bool {
        var entries = readEntries() ?? [
            "version": 1,
            "categories": [Any](),
            "assets": [Any]()
        ]
        var categories = entries["categories"] as? [[String: Any]] ?? []
        var assets = entries["assets"] as? [[String: Any]] ?? []

        let videoURLString = installedVideoURL.absoluteString
        let thumbnailURLString = thumbnailURL.absoluteString

        let subcategory: [String: Any] = [
            "id": subcategoryID,
            "localizedNameKey": displayName,
            "localizedDescriptionKey": "Custom video wallpaper",
            "preferredOrder": 0,
            "previewImage": thumbnailURLString,
            "representativeAssetID": assetID
        ]
        let category: [String: Any] = [
            "id": categoryID,
            "localizedNameKey": displayName,
            "localizedDescriptionKey": "Custom video wallpaper",
            "preferredOrder": 999,
            "representativeAssetID": assetID,
            "previewImage": thumbnailURLString,
            "subcategories": [subcategory]
        ]
        let asset: [String: Any] = [
            "id": assetID,
            "localizedNameKey": displayName,
            "accessibilityLabel": displayName,
            "shotID": "MONKEY_WALLPAPER",
            "showInTopLevel": true,
            "includeInShuffle": true,
            "preferredOrder": 0,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": videoURLString,
            "previewImage": thumbnailURLString,
            "pointsOfInterest": ["0": "MONKEY_0"]
        ]

        categories.removeAll { ($0["id"] as? String) == categoryID }
        categories.append(category)
        assets.removeAll { ($0["id"] as? String) == assetID }
        assets.append(asset)
        entries["categories"] = categories
        entries["assets"] = assets

        do {
            let data = try JSONSerialization.data(
                withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: entriesURL, options: .atomic)
            appLog("Aerials: entries.json updated")
            return true
        } catch {
            appLog("Aerials: entries.json write failed: \(error)")
            return false
        }
    }

    private func removeFromEntries() {
        guard var entries = readEntries() else { return }
        if var categories = entries["categories"] as? [[String: Any]] {
            categories.removeAll { ($0["id"] as? String) == categoryID }
            entries["categories"] = categories
        }
        if var assets = entries["assets"] as? [[String: Any]] {
            assets.removeAll { ($0["id"] as? String) == assetID }
            entries["assets"] = assets
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: entriesURL, options: .atomic)
        }
    }

    // MARK: - Wallpaper store

    private func loadStore() -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let dictionary = plist as? [String: Any] else { return nil }
        return dictionary
    }

    private func assetID(from scope: [String: Any], key: String) -> String? {
        guard let part = scope[key] as? [String: Any],
              let content = part["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let configuration = choices.first?["Configuration"] as? Data,
              let plist = try? PropertyListSerialization.propertyList(
                  from: configuration, options: [], format: nil
              ),
              let dictionary = plist as? [String: Any] else { return nil }
        return dictionary["assetID"] as? String
    }

    private func currentIdleAssetID() -> String? {
        guard let store = loadStore(),
              let scope = store["AllSpacesAndDisplays"] as? [String: Any] else { return nil }
        return assetID(from: scope, key: "Idle")
    }

    private func currentDesktopAssetID() -> String? {
        guard let store = loadStore(),
              let scope = store["AllSpacesAndDisplays"] as? [String: Any] else { return nil }
        return assetID(from: scope, key: "Desktop")
    }

    private func updateStore() -> Bool {
        guard var store = loadStore(),
              var scope = store["AllSpacesAndDisplays"] as? [String: Any] else {
            appLog("Aerials: unexpected wallpaper store structure")
            return false
        }

        guard let configuration = try? PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID], format: .binary, options: 0
        ) else { return false }

        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [Any](),
            "Configuration": configuration
        ]

        guard applyChoice(to: &scope, choice: choice) else {
            appLog("Aerials: desktop selection missing in store")
            return false
        }
        store["AllSpacesAndDisplays"] = scope

        if var systemScope = store["SystemDefault"] as? [String: Any] {
            _ = applyChoice(to: &systemScope, choice: choice)
            store["SystemDefault"] = systemScope
        }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: store, format: .binary, options: 0
            )
            try data.write(to: storeURL, options: .atomic)
            appLog("Aerials: wallpaper store updated (desktop + lock screen)")
            return true
        } catch {
            appLog("Aerials: wallpaper store write failed: \(error)")
            return false
        }
    }

    /// Sets both the desktop wallpaper and the Idle (lock screen / screen saver)
    /// selection to the injected aerial. macOS takes the immediate lock-screen
    /// background from the desktop choice, so both have to point at the video.
    private func applyChoice(to scope: inout [String: Any], choice: [String: Any]) -> Bool {
        guard let desktop = scope["Desktop"] as? [String: Any],
              let desktopContent = desktop["Content"] as? [String: Any] else { return false }

        let desktopProvider = (desktopContent["Choices"] as? [[String: Any]])?
            .first?["Provider"] as? String
        let aerialOptions = desktopProvider == "com.apple.wallpaper.choice.aerials"
            ? desktopContent["EncodedOptionValues"]
            : nil

        scope["Desktop"] = updatedPart(desktop, choice: choice, options: nil)
        if let idle = scope["Idle"] as? [String: Any] {
            scope["Idle"] = updatedPart(idle, choice: choice, options: aerialOptions)
        }
        return true
    }

    private func updatedPart(
        _ part: [String: Any],
        choice: [String: Any],
        options: Any?
    ) -> [String: Any] {
        var part = part
        var content = part["Content"] as? [String: Any] ?? [:]
        content["Choices"] = [choice]
        if let options {
            content["EncodedOptionValues"] = options
        }
        part["Content"] = content
        part["LastSet"] = Date()
        part["LastUse"] = Date()
        return part
    }

    // MARK: - WallpaperAgent

    private func restartWallpaperAgent() {
        if let items = try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path) {
            for item in items where item.hasSuffix(".bmp") {
                try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(item))
            }
            try? Data("{\"version\":0}".utf8).write(
                to: cacheDirectory.appendingPathComponent("cacheVersion.db")
            )
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        do {
            try task.run()
            appLog("Aerials: WallpaperAgent restart requested")
        } catch {
            appLog("Aerials: could not restart WallpaperAgent: \(error)")
        }
    }

    // MARK: - Thumbnail

    private func generateThumbnail(from videoURL: URL, to outputURL: URL) {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ImageBox()

        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            box.image = image
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)

        guard let image = box.image else {
            appLog("Aerials: thumbnail generation failed")
            return
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: outputURL, options: .atomic)
    }

    // MARK: - Helpers

    private func fileSize(_ url: URL) -> Int {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
}
