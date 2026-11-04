import AppKit
import AVFoundation
import Combine

// MARK: - Model

struct WallpaperItem: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var file: String
    var duration: Double
    var addedAt: Date

    var durationText: String {
        guard duration.isFinite, duration > 0 else { return "" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LibraryIndex: Codable {
    var activeID: String?
    var items: [WallpaperItem]
    var screenAssignments: [String: String]?
}

private final class LibraryImageBox: @unchecked Sendable {
    var image: CGImage?
}

private enum LibraryImportError: Error {
    case unplayable
}

// MARK: - Library

/// Owns the video collection: copies imported videos, generates thumbnails and
/// keeps a small JSON index next to them. All UI-facing state is published on
/// the main thread.
final class WallpaperLibrary: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    @Published private(set) var activeID: String?
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var preparingIDs: Set<String> = []
    @Published private(set) var isImporting = false
    @Published private(set) var screenAssignments: [String: String] = [:]

    let directory: URL

    private let root: URL
    private let indexURL: URL
    private let fileManager = FileManager.default
    private var transcodes: [String: LockVideoEncoder] = [:]

    init(root: URL) {
        self.root = root
        self.directory = root.appendingPathComponent("library", isDirectory: true)
        self.indexURL = directory.appendingPathComponent("library.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        loadIndex()
    }

    var activeItem: WallpaperItem? {
        guard let activeID else { return nil }
        return items.first { $0.id == activeID }
    }

    // MARK: Paths

    func fileURL(for item: WallpaperItem) -> URL {
        directory.appendingPathComponent(item.file)
    }

    func item(matching url: URL) -> WallpaperItem? {
        let target = url.standardizedFileURL
        return items.first { fileURL(for: $0).standardizedFileURL == target }
    }

    func sidecarURL(for item: WallpaperItem) -> URL {
        directory.appendingPathComponent("\(item.id)-lock.mov")
    }

    private func thumbnailURL(for item: WallpaperItem) -> URL {
        directory.appendingPathComponent("\(item.id).jpg")
    }

    // MARK: Bootstrap / migration

    /// Loads the library and makes sure the video referenced by the config is
    /// part of it. Older single-video installs are migrated automatically.
    /// Returns the file URL that should be played on the desktop.
    @discardableResult
    func bootstrap(currentVideoURL: URL?) -> URL? {
        var changed = false

        if let current = currentVideoURL,
           fileManager.fileExists(atPath: current.path) {
            if let match = item(matching: current) {
                if activeID != match.id {
                    activeID = match.id
                    changed = true
                }
            } else if let imported = try? importFile(at: current, move: isLegacy(current)) {
                items.append(imported)
                loadThumbnail(for: imported)
                activeID = imported.id
                changed = true
            }
        }

        if activeID == nil, let first = items.first {
            activeID = first.id
            changed = true
        }

        if changed {
            save()
        }

        return activeItem.map { fileURL(for: $0) }
    }

    private func isLegacy(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
            && url.lastPathComponent.hasPrefix("wallpaper.")
    }

    // MARK: Import

    func importVideos(_ urls: [URL], completion: @escaping ([WallpaperItem], [String]) -> Void) {
        let known = Set(items.map { fileURL(for: $0).standardizedFileURL })
        let newURLs = urls.filter { !known.contains($0.standardizedFileURL) }
        guard !newURLs.isEmpty else {
            completion([], [])
            return
        }

        isImporting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var imported: [WallpaperItem] = []
            var rejected: [String] = []

            for url in newURLs {
                do {
                    imported.append(try self.importFile(at: url, move: false))
                } catch {
                    rejected.append(url.lastPathComponent)
                    appLog("Library: import failed for \(url.path): \(error)")
                }
            }

            DispatchQueue.main.async {
                for item in imported where !self.items.contains(where: { $0.id == item.id }) {
                    self.items.append(item)
                    self.loadThumbnail(for: item)
                }
                self.isImporting = false
                if !imported.isEmpty {
                    self.save()
                }
                completion(imported, rejected)
            }
        }
    }

    private func importFile(at source: URL, move: Bool) throws -> WallpaperItem {
        guard isPlayableVideo(source) else {
            throw LibraryImportError.unplayable
        }

        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased()
        let id = UUID().uuidString
        let destination = directory.appendingPathComponent("\(id).\(ext)")

        if move {
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                try fileManager.copyItem(at: source, to: destination)
            }
        } else {
            try fileManager.copyItem(at: source, to: destination)
        }

        let originalTitle = source.deletingPathExtension().lastPathComponent
        let title = originalTitle.lowercased() == "wallpaper" ? "Monkey Wallpaper" : originalTitle
        let item = WallpaperItem(
            id: id,
            title: title,
            file: destination.lastPathComponent,
            duration: videoDuration(of: destination),
            addedAt: Date()
        )

        generateThumbnail(for: item)

        // Preserve the existing 4K lock-screen sidecar when migrating the old
        // single-video layout, so it does not have to be encoded again.
        if move {
            let legacySidecar = root.appendingPathComponent("lock-wallpaper.mov")
            if fileManager.fileExists(atPath: legacySidecar.path) {
                try? fileManager.removeItem(at: sidecarURL(for: item))
                try? fileManager.moveItem(at: legacySidecar, to: sidecarURL(for: item))
            }
        }

        appLog("Library: imported \(destination.lastPathComponent) (\(fileSize(destination)) bytes)")
        return item
    }

    // MARK: Selection / removal

    func setActive(_ item: WallpaperItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        activeID = item.id
        save()
    }

    func assign(_ item: WallpaperItem, toScreen key: String) {
        screenAssignments[key] = screenAssignments[key] == item.id ? nil : item.id
        save()
    }

    func clearScreenAssignments() {
        guard !screenAssignments.isEmpty else { return }
        screenAssignments = [:]
        save()
    }

    func nextItem(shuffled: Bool) -> WallpaperItem? {
        let others = items.filter { $0.id != activeID }
        if shuffled {
            return others.randomElement()
        }
        guard !others.isEmpty else { return nil }
        guard let index = items.firstIndex(where: { $0.id == activeID }) else { return items.first }
        return items[(index + 1) % items.count]
    }

    func remove(_ item: WallpaperItem) {
        transcodes[item.id]?.cancel()
        try? fileManager.removeItem(at: fileURL(for: item))
        try? fileManager.removeItem(at: thumbnailURL(for: item))
        try? fileManager.removeItem(at: sidecarURL(for: item))

        items.removeAll { $0.id == item.id }
        thumbnails.removeValue(forKey: item.id)
        preparingIDs.remove(item.id)
        screenAssignments = screenAssignments.filter { $0.value != item.id }

        if activeID == item.id {
            activeID = items.first?.id
        }
        save()
        appLog("Library: removed \(item.file)")
    }

    /// Deletes every library file, including thumbnails and 4K lock-screen
    /// sidecars, then writes an empty index. The app keeps running.
    func removeAll() {
        cancelTranscodes()
        for item in items {
            try? fileManager.removeItem(at: fileURL(for: item))
            try? fileManager.removeItem(at: thumbnailURL(for: item))
            try? fileManager.removeItem(at: sidecarURL(for: item))
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in contents where file.lastPathComponent != indexURL.lastPathComponent {
            try? fileManager.removeItem(at: file)
        }

        items = []
        activeID = nil
        thumbnails = [:]
        preparingIDs = []
        screenAssignments = [:]
        save()
        appLog("Library: all videos removed")
    }

    var totalSizeText: String {
        var bytes: Int64 = 0
        for item in items {
            bytes += Int64(max(0, fileSize(fileURL(for: item))))
            bytes += Int64(max(0, fileSize(thumbnailURL(for: item))))
            bytes += Int64(max(0, fileSize(sidecarURL(for: item))))
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Lock-screen sidecar

    func prepareLockSidecar(for item: WallpaperItem, completion: @escaping (URL?) -> Void) {
        let output = sidecarURL(for: item)
        if fileManager.fileExists(atPath: output.path) {
            completion(output)
            return
        }

        guard !preparingIDs.contains(item.id) else { return }

        let partial = fileManager.temporaryDirectory.appendingPathComponent("\(item.id)-lock.mov")
        try? fileManager.removeItem(at: partial)

        let encoder = LockVideoEncoder()
        preparingIDs.insert(item.id)
        transcodes[item.id] = encoder
        encoder.start(source: fileURL(for: item), destination: partial) { succeeded in
            DispatchQueue.main.async {
                self.finishLockSidecar(for: item, partial: partial, succeeded: succeeded, completion: completion)
            }
        }
    }

    func cancelTranscodes() {
        transcodes.values.forEach { $0.cancel() }
    }

    private func finishLockSidecar(
        for item: WallpaperItem,
        partial: URL,
        succeeded: Bool,
        completion: (URL?) -> Void
    ) {
        transcodes[item.id] = nil
        preparingIDs.remove(item.id)

        let output = sidecarURL(for: item)
        let stillInLibrary = items.contains { $0.id == item.id }
        if succeeded, stillInLibrary, (try? fileManager.moveItem(at: partial, to: output)) != nil {
            appLog("Library: lock-screen sidecar ready for \(item.file)")
            completion(output)
        } else {
            try? fileManager.removeItem(at: partial)
            appLog("Library: lock-screen sidecar failed for \(item.file)")
            completion(nil)
        }
    }

    // MARK: Thumbnails / metadata

    private func loadThumbnail(for item: WallpaperItem) {
        guard thumbnails[item.id] == nil else { return }
        if let image = NSImage(contentsOf: thumbnailURL(for: item)) {
            thumbnails[item.id] = image
        }
    }

    private func generateThumbnail(for item: WallpaperItem) {
        let asset = AVURLAsset(url: fileURL(for: item))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let seconds = min(1.0, max(0.2, item.duration * 0.1))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let semaphore = DispatchSemaphore(value: 0)
        let box = LibraryImageBox()

        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            box.image = image
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)

        guard let image = box.image else {
            appLog("Library: thumbnail generation failed for \(item.file)")
            return
        }

        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        ) else { return }
        try? data.write(to: thumbnailURL(for: item), options: .atomic)
    }

    private func videoDuration(of url: URL) -> Double {
        let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return seconds.isFinite ? seconds : 0
    }

    // MARK: Persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(LibraryIndex.self, from: data) else { return }

        let valid = index.items.filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
        items = valid
        activeID = valid.contains(where: { $0.id == index.activeID }) ? index.activeID : valid.first?.id
        screenAssignments = index.screenAssignments ?? [:]
        for item in valid {
            loadThumbnail(for: item)
        }
        if valid.count != index.items.count {
            save()
        }
    }

    private func save() {
        let index = LibraryIndex(activeID: activeID, items: items, screenAssignments: screenAssignments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: Helpers

    private func isPlayableVideo(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        return asset.isPlayable && asset.tracks(withMediaType: .video).contains { $0.isPlayable }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
}
