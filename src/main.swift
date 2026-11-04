import Cocoa
import AVFoundation
import IOKit.ps
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

// MARK: - Config

struct WallpaperConfig: Codable {
    var video: String
    var muted: Bool
    var pauseWhenAppActive: Bool
    var lockScreenVideo: Bool
    var pauseOnBattery: Bool
    var lockScreenAsked = false
    var loginItemConfigured = false
    var rotationMinutes = 0
    var rotationShuffle = false
    var lastRotation: Date?

    init(
        video: String = "wallpaper.mp4",
        muted: Bool = true,
        pauseWhenAppActive: Bool = false,
        lockScreenVideo: Bool = false,
        pauseOnBattery: Bool = false
    ) {
        self.video = video
        self.muted = muted
        self.pauseWhenAppActive = pauseWhenAppActive
        self.lockScreenVideo = lockScreenVideo
        self.pauseOnBattery = pauseOnBattery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        video = try container.decodeIfPresent(String.self, forKey: .video) ?? "wallpaper.mp4"
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        pauseWhenAppActive = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenAppActive) ?? false
        lockScreenVideo = try container.decodeIfPresent(Bool.self, forKey: .lockScreenVideo) ?? false
        pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
        lockScreenAsked = try container.decodeIfPresent(Bool.self, forKey: .lockScreenAsked)
            ?? container.contains(.lockScreenVideo)
        loginItemConfigured = try container.decodeIfPresent(Bool.self, forKey: .loginItemConfigured) ?? false
        rotationMinutes = try container.decodeIfPresent(Int.self, forKey: .rotationMinutes) ?? 0
        rotationShuffle = try container.decodeIfPresent(Bool.self, forKey: .rotationShuffle) ?? false
        lastRotation = try container.decodeIfPresent(Date.self, forKey: .lastRotation)
    }
}

// MARK: - App

final class WallpaperAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, SPUStandardUserDriverDelegate {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    var supportsGentleScheduledUpdateReminders: Bool { true }

    private var surfaces: [DesktopSurface] = []
    private var players: [URL: LoopingPlayer] = [:]

    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var focusMenuItem: NSMenuItem?
    private var lockMenuItem: NSMenuItem?
    private let videoMenu = NSMenu()

    private var config = WallpaperConfig()
    private var videoURL = supportDirectory.appendingPathComponent("wallpaper.mp4")
    private let library = WallpaperLibrary(root: supportDirectory)
    private var libraryWindowController: LibraryWindowController?
    private var settingsModel: SettingsModel?
    private var settingsWindowController: SettingsWindowController?

    private var manuallyPaused = false
    private var systemPaused = false
    private var focusPaused = false
    private var screensaverActive = false
    private var sessionActive = true
    private var powerPaused = false
    private var playbackFailed = false
    private var refreshWorkItem: DispatchWorkItem?
    private var persistenceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadConfig()

        if let activeURL = library.bootstrap(currentVideoURL: videoURL) {
            videoURL = activeURL
            if let item = library.activeItem {
                config.video = "library/\(item.file)"
                saveConfig()
            }
        } else {
            appLog("Library bootstrap produced no video")
        }

        settingsModel = SettingsModel(
            pauseWhenAppActive: config.pauseWhenAppActive,
            lockScreenVideo: config.lockScreenVideo,
            muted: config.muted,
            pauseOnBattery: config.pauseOnBattery,
            libraryCount: library.items.count,
            librarySizeText: library.totalSizeText,
            libraryPath: library.directory.path
        )

        NSApp.setActivationPolicy(.accessory)

        setupMainMenu()
        setupStatusItem()
        setupObservers()
        configureLoginItem()
        updatePowerPause()
        rebuildWindows()
        updateFocusPause()
        startWindowPersistence()

        if config.lockScreenVideo, let item = library.activeItem {
            installLockScreen(for: item, force: false, select: false)
        }

        if library.items.isEmpty && !config.lockScreenAsked {
            openLibrary()
        }

        appLog("Launched. video=\(videoURL.path) screens=\(NSScreen.screens.count) library=\(library.items.count) lock=\(config.lockScreenVideo) focusPause=\(config.pauseWhenAppActive) loginItem=\(SMAppService.mainApp.status.rawValue) language=\(Bundle.main.preferredLocalizations.first ?? "")")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openLibrary()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshWorkItem?.cancel()
        persistenceTimer?.invalidate()
        library.cancelTranscodes()
        teardownWindows()
        appLog("Terminated.")
    }

    // MARK: - Setup

    private func loadConfig() {
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(WallpaperConfig.self, from: data) {
            config = decoded
        }

        if config.video.hasPrefix("/") {
            videoURL = URL(fileURLWithPath: config.video)
        } else {
            videoURL = supportDirectory.appendingPathComponent(config.video)
        }
        saveConfig()
    }

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard var data = try? encoder.encode(config) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }

    private func configureLoginItem() {
        guard !config.loginItemConfigured else { return }

        do {
            try SMAppService.mainApp.register()
            try? FileManager.default.removeItem(at: legacyLaunchAgentURL)
            config.loginItemConfigured = true
            saveConfig()
            appLog("Login item registered")
        } catch {
            appLog("Login item could not be registered: \(error)")
        }
    }

    private func setupMainMenu() {
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu

        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(windowItem)
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "MonkeWall"
        statusItem = item
        setStatusIcon(warning: false)

        let menu = NSMenu()
        let header = NSMenuItem(title: "MonkeWall", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let libraryItem = NSMenuItem(title: L("Library…"), action: #selector(openLibrary), keyEquivalent: "l")
        libraryItem.target = self
        menu.addItem(libraryItem)

        let choose = NSMenuItem(title: L("Add Videos…"), action: #selector(chooseVideo), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        let videos = NSMenuItem(title: L("Videos"), action: nil, keyEquivalent: "")
        videoMenu.delegate = self
        videos.submenu = videoMenu
        menu.addItem(videos)

        let next = NSMenuItem(title: L("Next Video"), action: #selector(showNextVideo), keyEquivalent: "n")
        next.target = self
        menu.addItem(next)

        menu.addItem(.separator())

        let pause = NSMenuItem(title: L("Pause"), action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseMenuItem = pause

        let focus = NSMenuItem(title: L("Pause When Another App Is Active"), action: #selector(toggleFocusPause), keyEquivalent: "")
        focus.target = self
        menu.addItem(focus)
        focusMenuItem = focus

        let lock = NSMenuItem(title: L("Play on Lock Screen"), action: #selector(toggleLockScreenVideo), keyEquivalent: "")
        lock.target = self
        menu.addItem(lock)
        lockMenuItem = lock

        let reload = NSMenuItem(title: L("Reload"), action: #selector(reloadWallpaper), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(
            title: L("Check for Updates…"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updates.target = updaterController
        menu.addItem(updates)

        let about = NSMenuItem(title: L("About"), action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("Quit"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        updateMenuStates()
    }

    private func setStatusIcon(warning: Bool) {
        guard let button = statusItem?.button else { return }

        if warning {
            button.image = nil
            button.title = "⚠️"
            return
        }

        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.title = ""
            button.image = image
        } else {
            button.title = "🐒"
        }
    }

    private func updateMenuStates() {
        pauseMenuItem?.title = manuallyPaused ? L("Resume") : L("Pause")
        focusMenuItem?.state = config.pauseWhenAppActive ? .on : .off
        lockMenuItem?.state = config.lockScreenVideo ? .on : .off
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard !library.items.isEmpty else {
            menu.addItem(NSMenuItem(title: L("No Videos"), action: nil, keyEquivalent: ""))
            return
        }

        for item in library.items {
            let entry = NSMenuItem(title: item.title, action: #selector(videoMenuItemSelected(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item
            entry.state = item.id == library.activeID ? .on : .off
            if let thumbnail = library.thumbnails[item.id]?.copy() as? NSImage {
                thumbnail.size = NSSize(width: 32, height: 18)
                entry.image = thumbnail
            }
            menu.addItem(entry)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(showNextVideo) || library.items.count > 1
    }

    @objc private func videoMenuItemSelected(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? WallpaperItem else { return }
        selectVideo(item)
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(displayDidSleep),
                                    name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(displayDidWake),
                                    name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(screenLocked),
                                    name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(screenUnlocked),
                                    name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(frontmostAppChanged),
                                    name: NSWorkspace.didActivateApplicationNotification, object: nil)

        setupLockNotifications()
        setupPowerNotifications()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screensaverStarted),
            name: NSNotification.Name("com.apple.screensaver.didStart"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screensaverStopped),
            name: NSNotification.Name("com.apple.screensaver.didStop"),
            object: nil
        )
    }

    /// Kernel-level lock/unlock notifications. They arrive earlier and more
    /// reliably than NSWorkspace's session notifications on current macOS.
    private func setupLockNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<WallpaperAppDelegate>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { delegate.screenLocked() }
            },
            "com.apple.sessionagent.screenIsLocked" as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<WallpaperAppDelegate>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { delegate.screenUnlocked() }
            },
            "com.apple.sessionagent.screenIsUnlocked" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func setupPowerNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let delegate = Unmanaged<WallpaperAppDelegate>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            DispatchQueue.main.async { delegate.updatePowerPause() }
        }, context)?.takeRetainedValue()

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    // MARK: - Windows

    private func rebuildWindows() {
        teardownWindows()

        guard !library.items.isEmpty else {
            appLog("No videos in library; desktop overlay stopped")
            setStatusIcon(warning: false)
            return
        }

        guard !playbackFailed else { return }

        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            appLog("Video not found at \(videoURL.path)")
            setStatusIcon(warning: true)
            return
        }
        setStatusIcon(warning: false)

        let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

        for screen in NSScreen.screens {
            let surface = DesktopSurface(screen: screen, level: windowLevel)
            let url = videoURL(forScreen: surface.screenKey)
            surface.show(loopingPlayer(for: url).player, url: url, animated: false) {}
            if sessionActive {
                surface.window.orderFrontRegardless()
            }
            surfaces.append(surface)

            appLog("Window created: \(screen.frame) level=\(windowLevel.rawValue)")
        }

        updateMuting()
        applyPlayback()
    }

    private func refreshSurfaces() {
        guard !surfaces.isEmpty else {
            rebuildWindows()
            return
        }

        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for surface in surfaces {
            let url = videoURL(forScreen: surface.screenKey)
            guard surface.videoURL != url else { continue }
            surface.show(loopingPlayer(for: url).player, url: url, animated: animated) { [weak self] in
                self?.pruneUnusedPlayers()
            }
        }

        updateMuting()
        applyPlayback()
    }

    private func teardownWindows() {
        surfaces.forEach { $0.window.orderOut(nil) }
        surfaces.removeAll()
        players.removeAll()
    }

    private func videoURL(forScreen key: String) -> URL {
        guard let id = library.screenAssignments[key],
              let item = library.items.first(where: { $0.id == id }) else { return videoURL }
        return library.fileURL(for: item)
    }

    private func loopingPlayer(for url: URL) -> LoopingPlayer {
        if let existing = players[url] {
            return existing
        }
        let created = LoopingPlayer(url: url) { [weak self] error in
            self?.handlePlaybackFailure(error, url: url)
        }
        players[url] = created
        return created
    }

    private func pruneUnusedPlayers() {
        guard !surfaces.contains(where: \.isFading) else { return }
        let inUse = Set(surfaces.compactMap(\.videoURL))
        players = players.filter { inUse.contains($0.key) }
        appLog("Crossfade finished, players=\(players.count)")
    }

    private func updateMuting() {
        for (url, looping) in players {
            looping.player.isMuted = config.muted || url != videoURL
        }
    }

    private func handlePlaybackFailure(_ error: Error?, url: URL) {
        guard !playbackFailed else { return }
        appLog("Video playback failed: \(String(describing: error))")
        playbackFailed = true
        teardownWindows()
        setStatusIcon(warning: true)
        showAlert(
            L("Video Couldn't Be Played"),
            String(
                format: L("%@ couldn't be played. Choose another video from the library."),
                library.item(matching: url)?.title ?? L("The selected video")
            )
        )
    }

    // MARK: - Playback

    private func applyPlayback() {
        let canPlay = sessionActive
            && !manuallyPaused
            && !systemPaused
            && !focusPaused
            && !screensaverActive
            && !powerPaused
        for (url, looping) in players {
            if canPlay && surfaces.contains(where: { $0.uses(url) && $0.isVisible }) {
                looping.player.play()
            } else {
                looping.player.pause()
            }
        }
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        guard surfaces.contains(where: { $0.window === notification.object as? NSWindow }) else { return }
        applyPlayback()
        appLog("Visible surfaces: \(surfaces.filter(\.isVisible).count)/\(surfaces.count)")
    }

    private func updatePowerPause() {
        let paused = config.pauseOnBattery
            && (isOnBattery() || ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard powerPaused != paused else { return }
        powerPaused = paused
        applyPlayback()
        appLog("Power pause: \(paused)")
    }

    private func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return source as String == kIOPSBatteryPowerValue
    }

    private func updateFocusPause() {
        guard config.pauseWhenAppActive else {
            setFocusPaused(false)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isFinder = frontmost == "com.apple.finder"
        let isSelf = frontmost == Bundle.main.bundleIdentifier
        setFocusPaused(frontmost != nil && !isFinder && !isSelf)
    }

    private func setFocusPaused(_ paused: Bool) {
        guard focusPaused != paused else { return }
        focusPaused = paused
        applyPlayback()
        appLog("Focus pause: \(paused)")
    }

    // MARK: - Actions

    @objc private func chooseVideo() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = L("Choose videos to add to the library.")
        panel.prompt = L("Add to Library")

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addVideos(panel.urls)
    }

    @objc private func openLibrary() {
        if libraryWindowController == nil {
            libraryWindowController = LibraryWindowController(
                library: library,
                onAdd: { [weak self] in self?.chooseVideo() },
                onSelect: { [weak self] item in self?.selectVideo(item) },
                onAssign: { [weak self] item, screenKey in self?.assignVideo(item, toScreen: screenKey) },
                onReveal: { [weak self] item in
                    guard let self else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([self.library.fileURL(for: item)])
                },
                onRemove: { [weak self] item in self?.removeLibraryItem(item) },
                onDropVideos: { [weak self] urls in self?.addVideos(urls) }
            )
        }
        libraryWindowController?.present()
    }

    private func addVideos(_ urls: [URL]) {
        library.importVideos(urls) { [weak self] imported, rejected in
            guard let self else { return }
            if let first = imported.first {
                self.applyLibraryItem(first)
                self.askLockScreenIfNeeded()
            }
            if !rejected.isEmpty {
                self.showAlert(
                    L("Couldn't Add Videos"),
                    String(
                        format: L("These files can't be played or couldn't be copied:\n%@"),
                        rejected.joined(separator: "\n")
                    )
                )
            }
        }
    }

    private func askLockScreenIfNeeded() {
        guard !config.lockScreenAsked else { return }
        config.lockScreenAsked = true
        saveConfig()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Play on the Lock Screen Too?")
        alert.informativeText = L("MonkeWall registers the video as your macOS wallpaper and lock screen. Your current wallpaper is backed up, and you can turn this off in Settings at any time.")
        alert.addButton(withTitle: L("Yes, Play It"))
        alert.addButton(withTitle: L("Not Now"))
        if alert.runModal() == .alertFirstButtonReturn {
            setLockScreenEnabled(true)
        }
    }

    private func selectVideo(_ item: WallpaperItem) {
        library.clearScreenAssignments()
        playbackFailed = false
        if item.id == library.activeID {
            refreshSurfaces()
        } else {
            applyLibraryItem(item)
        }
    }

    private func assignVideo(_ item: WallpaperItem, toScreen key: String) {
        library.assign(item, toScreen: key)
        playbackFailed = false
        refreshSurfaces()
    }

    @objc private func showNextVideo() {
        guard let next = library.nextItem(shuffled: config.rotationShuffle) else { return }
        applyLibraryItem(next)
    }

    private func rotateIfDue() {
        guard config.rotationMinutes > 0,
              sessionActive,
              !manuallyPaused,
              !systemPaused,
              !screensaverActive,
              !powerPaused,
              Date().timeIntervalSince(config.lastRotation ?? .distantPast) >= Double(config.rotationMinutes) * 60
        else { return }
        showNextVideo()
    }

    private func applyLibraryItem(_ item: WallpaperItem) {
        guard item.id != library.activeID else { return }

        let fileURL = library.fileURL(for: item)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            showAlert(
                L("Video Not Found"),
                String(format: L("The file for %@ wasn't found in the library."), item.title)
            )
            return
        }

        playbackFailed = false
        videoURL = fileURL
        library.setActive(item)
        config.video = "library/\(item.file)"
        config.lastRotation = Date()
        saveConfig()
        refreshSettingsModel()
        refreshSurfaces()
        updateFocusPause()

        if config.lockScreenVideo {
            installLockScreen(for: item, force: true)
        }

        appLog("Video changed to \(fileURL.path)")
    }

    private func removeLibraryItem(_ item: WallpaperItem) {
        if item.id == library.activeID {
            if let next = library.items.first(where: { $0.id != item.id }) {
                applyLibraryItem(next)
            } else {
                // Last video: remove every file and give the desktop back to
                // the wallpaper that was there before MonkeWall.
                deleteAllLibrary()
                return
            }
        }

        library.remove(item)
        refreshSurfaces()
        refreshSettingsModel()
    }

    /// Installs the active video on the native lock screen. If a 4K HEVC
    /// sidecar does not exist yet, it is encoded in the background; until it is
    /// ready the desktop keeps playing and the previous lock-screen asset stays.
    private func installLockScreen(
        for item: WallpaperItem,
        force: Bool,
        select: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        let sidecar = library.sidecarURL(for: item)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            let installed = AerialsManager.shared.install(videoURL: sidecar, force: force, select: select)
            if !installed {
                appLog("Lock screen installation failed for \(item.file)")
            }
            completion?(installed)
            return
        }

        library.prepareLockSidecar(for: item) { [weak self] generated in
            guard let self else { return }
            guard self.config.lockScreenVideo else {
                completion?(false)
                return
            }
            guard self.library.activeID == item.id else {
                completion?(false)
                return
            }

            let source = generated ?? self.library.fileURL(for: item)
            let installed = AerialsManager.shared.install(videoURL: source, force: true, select: select)
            if !installed {
                appLog("Lock screen installation failed for \(item.file)")
            }
            completion?(installed)
        }
    }

    @objc private func togglePause() {
        manuallyPaused.toggle()
        pauseMenuItem?.title = manuallyPaused ? L("Resume") : L("Pause")
        applyPlayback()
        appLog(manuallyPaused ? "Paused by user." : "Resumed by user.")
    }

    @objc private func toggleFocusPause() {
        setFocusPauseEnabled(!config.pauseWhenAppActive)
    }

    private func setFocusPauseEnabled(_ enabled: Bool) {
        config.pauseWhenAppActive = enabled
        focusMenuItem?.state = enabled ? .on : .off
        saveConfig()
        updateFocusPause()
        refreshSettingsModel()
        appLog("Focus pause setting: \(enabled)")
    }

    @objc private func toggleLockScreenVideo() {
        setLockScreenEnabled(!config.lockScreenVideo)
    }

    private func setLockScreenEnabled(_ enabled: Bool) {
        guard enabled != config.lockScreenVideo else {
            refreshSettingsModel()
            return
        }

        if !enabled {
            let restored = AerialsManager.shared.remove()
            config.lockScreenVideo = false
            lockMenuItem?.state = .off
            saveConfig()
            refreshSettingsModel()
            appLog("Lock screen video disabled")
            if !restored {
                showLockScreenRestoreFailure()
            }
            return
        }

        guard let item = library.activeItem else {
            refreshSettingsModel()
            showAlert(L("No Videos"), L("Add a video to the library first."))
            return
        }

        config.lockScreenVideo = true
        lockMenuItem?.state = .on
        saveConfig()
        refreshSettingsModel()
        appLog("Lock screen video enabled")

        installLockScreen(for: item, force: true) { [weak self] installed in
            guard let self, !installed else { return }
            self.config.lockScreenVideo = false
            self.lockMenuItem?.state = .off
            self.saveConfig()
            self.refreshSettingsModel()
            self.showAlert(
                L("Couldn't Set the Lock Screen"),
                L("macOS's wallpaper store couldn't be written. You can try again from System Settings > Wallpaper.")
            )
        }
    }

    private func setMuted(_ muted: Bool) {
        config.muted = muted
        saveConfig()
        updateMuting()
        refreshSettingsModel()
        appLog("Muted: \(muted)")
    }

    private func setBatteryPauseEnabled(_ enabled: Bool) {
        config.pauseOnBattery = enabled
        saveConfig()
        updatePowerPause()
        refreshSettingsModel()
        appLog("Battery pause setting: \(enabled)")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appLog("Login item change failed: \(error)")
        }
        if enabled && SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshSettingsModel()
    }

    private func setAutomaticUpdateChecks(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
        refreshSettingsModel()
    }

    private func setRotation(minutes: Int) {
        config.rotationMinutes = minutes
        config.lastRotation = Date()
        saveConfig()
        refreshSettingsModel()
    }

    private func setRotationShuffle(_ enabled: Bool) {
        config.rotationShuffle = enabled
        saveConfig()
        refreshSettingsModel()
    }

    private func uninstallApp() {
        library.cancelTranscodes()
        guard uninstallEverything() else {
            showLockScreenRestoreFailure()
            return
        }
        try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        exit(0)
    }

    private func showLockScreenRestoreFailure() {
        showAlert(
            L("Couldn't Restore the Previous Wallpaper"),
            L("The backup couldn't be used. You can choose another wallpaper and screen saver in System Settings.")
        )
    }

    // MARK: - Settings

    @objc private func openSettings() {
        presentSettings(tab: .general)
    }

    @objc private func openAbout() {
        presentSettings(tab: .about)
    }

    private func presentSettings(tab: SettingsTab) {
        if settingsModel == nil {
            settingsModel = SettingsModel(
                pauseWhenAppActive: config.pauseWhenAppActive,
                lockScreenVideo: config.lockScreenVideo,
                muted: config.muted,
                pauseOnBattery: config.pauseOnBattery,
                libraryCount: library.items.count,
                librarySizeText: library.totalSizeText,
                libraryPath: library.directory.path
            )
        }

        refreshSettingsModel()

        if settingsWindowController == nil, let settingsModel {
            settingsWindowController = SettingsWindowController(
                model: settingsModel,
                onPauseChange: { [weak self] value in self?.setFocusPauseEnabled(value) },
                onLockScreenChange: { [weak self] value in self?.setLockScreenEnabled(value) },
                onMuteChange: { [weak self] value in self?.setMuted(value) },
                onBatteryPauseChange: { [weak self] value in self?.setBatteryPauseEnabled(value) },
                onLaunchAtLoginChange: { [weak self] value in self?.setLaunchAtLogin(value) },
                onAutomaticUpdatesChange: { [weak self] value in self?.setAutomaticUpdateChecks(value) },
                onRotationChange: { [weak self] value in self?.setRotation(minutes: value) },
                onShuffleChange: { [weak self] value in self?.setRotationShuffle(value) },
                onUninstall: { [weak self] in self?.uninstallApp() },
                onOpenLibrary: { [weak self] in self?.openLibrary() },
                onRevealLibraryFolder: { [weak self] in
                    guard let self else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([self.library.directory])
                },
                onDeleteAll: { [weak self] in self?.deleteAllLibrary() }
            )
        }

        settingsModel?.selectedTab = tab
        settingsWindowController?.present()
    }

    private func refreshSettingsModel() {
        settingsModel?.pauseWhenAppActive = config.pauseWhenAppActive
        settingsModel?.lockScreenVideo = config.lockScreenVideo
        settingsModel?.muted = config.muted
        settingsModel?.pauseOnBattery = config.pauseOnBattery
        settingsModel?.launchAtLogin = SMAppService.mainApp.status == .enabled
        settingsModel?.automaticUpdateChecks = updaterController.updater.automaticallyChecksForUpdates
        settingsModel?.rotationMinutes = config.rotationMinutes
        settingsModel?.rotationShuffle = config.rotationShuffle
        settingsModel?.libraryCount = library.items.count
        settingsModel?.librarySizeText = library.totalSizeText
        settingsModel?.libraryPath = library.directory.path
    }

    /// Removes all library files (videos, thumbnails, 4K lock copies) and
    /// restores the wallpaper that was active before MonkeWall.
    private func deleteAllLibrary() {
        guard !library.items.isEmpty else {
            refreshSettingsModel()
            return
        }

        let restored = AerialsManager.shared.remove()
        config.video = "wallpaper.mp4"
        saveConfig()

        library.removeAll()
        videoURL = supportDirectory.appendingPathComponent("wallpaper.mp4")
        teardownWindows()
        updateMenuStates()
        refreshSettingsModel()
        setStatusIcon(warning: false)
        appLog("Library cleared; previous wallpaper restored: \(restored)")

        if !restored {
            showLockScreenRestoreFailure()
        }
    }

    @objc private func reloadWallpaper() {
        loadConfig()
        playbackFailed = false

        if let activeURL = library.bootstrap(currentVideoURL: videoURL) {
            videoURL = activeURL
            if let item = library.activeItem {
                config.video = "library/\(item.file)"
                saveConfig()
            }
        }

        updateMenuStates()
        updatePowerPause()
        rebuildWindows()
        updateFocusPause()
        refreshSettingsModel()

        if config.lockScreenVideo, let item = library.activeItem {
            installLockScreen(for: item, force: false)
            _ = AerialsManager.shared.refresh()
        }
        appLog("Reloaded. video=\(videoURL.path)")
    }

    @objc private func screensChanged() {
        appLog("Screen configuration changed.")
        rebuildWindows()
    }

    @objc private func frontmostAppChanged() {
        updateFocusPause()
    }

    @objc private func powerStateChanged() {
        DispatchQueue.main.async { [weak self] in self?.updatePowerPause() }
    }

    @objc private func displayDidSleep() {
        systemPaused = true
        hideWindows()
        applyPlayback()
        appLog("Display asleep")
    }

    @objc private func displayDidWake() {
        systemPaused = false
        if sessionActive {
            showWindows()
        }
        updateFocusPause()
        applyPlayback()
        appLog("Display awake (sessionActive=\(sessionActive))")
    }

    @objc private func screenLocked() {
        sessionActive = false
        systemPaused = true
        hideWindows()
        applyPlayback()
        appLog("Screen locked — overlay hidden")
    }

    @objc private func screenUnlocked() {
        sessionActive = true
        systemPaused = false
        updateFocusPause()
        applyPlayback()
        showWindows()
        appLog("Screen unlocked — overlay restored")
        scheduleLockScreenRefresh()
    }

    @objc private func screensaverStarted() {
        screensaverActive = true
        hideWindows()
        applyPlayback()
        appLog("Screen saver started")
    }

    @objc private func screensaverStopped() {
        screensaverActive = false
        if sessionActive {
            showWindows()
        }
        updateFocusPause()
        applyPlayback()
        scheduleLockScreenRefresh()
        appLog("Screen saver stopped")
    }

    private func hideWindows() {
        surfaces.forEach { $0.window.orderOut(nil) }
    }

    private func showWindows() {
        surfaces.forEach { $0.window.orderFrontRegardless() }
    }

    private func scheduleLockScreenRefresh() {
        refreshWorkItem?.cancel()
        guard config.lockScreenVideo else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.config.lockScreenVideo else { return }
            _ = AerialsManager.shared.refresh()
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - Window persistence

    private func startWindowPersistence() {
        persistenceTimer?.invalidate()
        persistenceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.enforceWindowVisibility()
            self?.rotateIfDue()
        }
        persistenceTimer?.tolerance = 1.0
    }

    /// macOS can order desktop-level windows out after unlock, screen changes or
    /// a missed notification. Re-assert them periodically; if the session is
    /// locked, keep them hidden so the native lock-screen video stays visible.
    private func enforceWindowVisibility() {
        if sessionIsLocked() {
            if sessionActive {
                screenLocked()
            }
            return
        }

        if !sessionActive {
            screenUnlocked()
            return
        }

        guard !screensaverActive else { return }

        if surfaces.isEmpty {
            if FileManager.default.fileExists(atPath: videoURL.path) {
                rebuildWindows()
            }
            return
        }

        for surface in surfaces {
            if let screen = NSScreen.screens.first(where: { $0.displayKey == surface.screenKey }),
               surface.window.frame != screen.frame {
                surface.window.setFrame(screen.frame, display: true)
            }
            if !surface.window.isVisible {
                surface.window.orderFrontRegardless()
            }
        }

        applyPlayback()
    }

    private func sessionIsLocked() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Int { return locked != 0 }
        return false
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

func uninstallEverything() -> Bool {
    guard AerialsManager.shared.remove() else { return false }

    let fileManager = FileManager.default

    try? SMAppService.mainApp.unregister()
    if let identifier = Bundle.main.bundleIdentifier {
        UserDefaults.standard.removePersistentDomain(forName: identifier)
        try? fileManager.removeItem(
            at: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(identifier)
        )
    }

    try? fileManager.removeItem(at: legacyLaunchAgentURL)
    try? fileManager.removeItem(at: supportDirectory)
    try? fileManager.removeItem(at: logURL.deletingLastPathComponent().appendingPathComponent("MonkeWall.stderr.log"))
    try? fileManager.removeItem(at: logURL)
    return true
}

// MARK: - Entry point

let arguments = CommandLine.arguments

if arguments.contains("--uninstall") {
    exit(uninstallEverything() ? 0 : 1)
}

if arguments.contains("--remove-lock-screen") {
    exit(AerialsManager.shared.remove() ? 0 : 1)
}

if let index = arguments.firstIndex(of: "--install-lock-screen"), index + 1 < arguments.count {
    let url = URL(fileURLWithPath: arguments[index + 1])
    let installed = AerialsManager.shared.install(videoURL: url, force: true)
    AerialsManager.shared.waitForThumbnail()
    exit(installed ? 0 : 1)
}

let application = NSApplication.shared
let delegate = WallpaperAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
