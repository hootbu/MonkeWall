import Cocoa
import AVFoundation
import AVKit
import UniformTypeIdentifiers

// MARK: - Config

struct WallpaperConfig: Codable {
    var video: String
    var muted: Bool
    var pauseWhenAppActive: Bool
    var lockScreenVideo: Bool

    init(
        video: String = "wallpaper.mp4",
        muted: Bool = true,
        pauseWhenAppActive: Bool = true,
        lockScreenVideo: Bool = true
    ) {
        self.video = video
        self.muted = muted
        self.pauseWhenAppActive = pauseWhenAppActive
        self.lockScreenVideo = lockScreenVideo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        video = try container.decodeIfPresent(String.self, forKey: .video) ?? "wallpaper.mp4"
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        pauseWhenAppActive = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenAppActive) ?? true
        lockScreenVideo = try container.decodeIfPresent(Bool.self, forKey: .lockScreenVideo) ?? true
    }
}

// MARK: - App

final class WallpaperAppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var players: [AVQueuePlayer] = []
    private var loopers: [AVPlayerLooper] = []
    private var observations: [NSKeyValueObservation] = []

    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var focusMenuItem: NSMenuItem?
    private var lockMenuItem: NSMenuItem?

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
            libraryCount: library.items.count,
            librarySizeText: library.totalSizeText,
            libraryPath: library.directory.path
        )

        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupObservers()
        rebuildWindows()
        updateFocusPause()
        startWindowPersistence()

        if config.lockScreenVideo, let item = library.activeItem {
            installLockScreen(for: item, force: false)
        }

        appLog("Launched. video=\(videoURL.path) screens=\(NSScreen.screens.count) library=\(library.items.count) lock=\(config.lockScreenVideo) focusPause=\(config.pauseWhenAppActive)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openLibrary()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshWorkItem?.cancel()
        persistenceTimer?.invalidate()
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

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "MonkeWall"
        statusItem = item
        setStatusIcon(warning: false)

        let menu = NSMenu()
        let header = NSMenuItem(title: "MonkeWall", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let libraryItem = NSMenuItem(title: "Kütüphane…", action: #selector(openLibrary), keyEquivalent: "l")
        libraryItem.target = self
        menu.addItem(libraryItem)

        let choose = NSMenuItem(title: "Video Ekle…", action: #selector(chooseVideo), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Duraklat", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseMenuItem = pause

        let focus = NSMenuItem(title: "Odaklanınca Duraklat", action: #selector(toggleFocusPause), keyEquivalent: "")
        focus.target = self
        menu.addItem(focus)
        focusMenuItem = focus

        let lock = NSMenuItem(title: "Kilit Ekranında Oynat", action: #selector(toggleLockScreenVideo), keyEquivalent: "")
        lock.target = self
        menu.addItem(lock)
        lockMenuItem = lock

        let reload = NSMenuItem(title: "Yeniden Yükle", action: #selector(reloadWallpaper), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "Hakkında", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Çıkış", action: #selector(quitApp), keyEquivalent: "q")
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
        pauseMenuItem?.title = manuallyPaused ? "Devam Et" : "Duraklat"
        focusMenuItem?.state = config.pauseWhenAppActive ? .on : .off
        lockMenuItem?.state = config.lockScreenVideo ? .on : .off
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
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

    // MARK: - Windows

    private func rebuildWindows() {
        teardownWindows()

        guard !library.items.isEmpty else {
            appLog("No videos in library; desktop overlay stopped")
            setStatusIcon(warning: false)
            return
        }

        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            appLog("Video not found at \(videoURL.path)")
            setStatusIcon(warning: true)
            return
        }
        setStatusIcon(warning: false)

        let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

        for screen in NSScreen.screens {
            let player = AVQueuePlayer()
            player.isMuted = config.muted
            player.preventsDisplaySleepDuringVideoPlayback = false

            let templateItem = AVPlayerItem(url: videoURL)
            let looper = AVPlayerLooper(player: player, templateItem: templateItem)

            if let currentItem = player.currentItem {
                observations.append(currentItem.observe(\.status, options: [.new]) { item, _ in
                    if item.status == .failed {
                        appLog("Video item failed: \(String(describing: item.error))")
                    }
                })
            }

            let playerView = AVPlayerView()
            playerView.player = player
            playerView.controlsStyle = .none
            playerView.videoGravity = .resizeAspectFill
            playerView.showsFullScreenToggleButton = false

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = windowLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.contentView = playerView
            window.setFrame(screen.frame, display: true)
            if sessionActive {
                window.orderFrontRegardless()
            }

            windows.append(window)
            players.append(player)
            loopers.append(looper)

            appLog("Window created: \(screen.frame) level=\(windowLevel.rawValue)")
        }

        applyPlayback()
    }

    private func teardownWindows() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        players.forEach { $0.pause() }
        players.removeAll()
        loopers.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: - Playback

    private func applyPlayback() {
        let shouldPlay = !manuallyPaused && !systemPaused && !focusPaused && !screensaverActive
        for player in players {
            shouldPlay ? player.play() : player.pause()
        }
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
        panel.message = "Kütüphaneye eklenecek videoları seç."
        panel.prompt = "Kütüphaneye Ekle"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addVideos(panel.urls)
    }

    @objc private func openLibrary() {
        if libraryWindowController == nil {
            libraryWindowController = LibraryWindowController(
                library: library,
                onAdd: { [weak self] in self?.chooseVideo() },
                onSelect: { [weak self] item in self?.applyLibraryItem(item) },
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
        library.importVideos(urls) { [weak self] imported in
            guard let self else { return }
            guard let first = imported.first else {
                appLog("Library: no new video was imported")
                return
            }
            self.applyLibraryItem(first)
        }
    }

    private func applyLibraryItem(_ item: WallpaperItem) {
        let fileURL = library.fileURL(for: item)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            showAlert("Video bulunamadı", "\(item.title) dosyası kütüphanede bulunamadı.")
            return
        }

        videoURL = fileURL
        library.setActive(item)
        config.video = "library/\(item.file)"
        saveConfig()
        refreshSettingsModel()
        rebuildWindows()
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
        refreshSettingsModel()
    }

    /// Installs the active video on the native lock screen. If a 4K HEVC
    /// sidecar does not exist yet, it is encoded in the background; until it is
    /// ready the desktop keeps playing and the previous lock-screen asset stays.
    private func installLockScreen(
        for item: WallpaperItem,
        force: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        let sidecar = library.sidecarURL(for: item)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            let installed = AerialsManager.shared.install(videoURL: sidecar, force: force)
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
            let installed = AerialsManager.shared.install(videoURL: source, force: true)
            if !installed {
                appLog("Lock screen installation failed for \(item.file)")
            }
            completion?(installed)
        }
    }

    @objc private func togglePause() {
        manuallyPaused.toggle()
        pauseMenuItem?.title = manuallyPaused ? "Devam Et" : "Duraklat"
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
            _ = AerialsManager.shared.remove()
            config.lockScreenVideo = false
            lockMenuItem?.state = .off
            saveConfig()
            refreshSettingsModel()
            appLog("Lock screen video disabled")
            return
        }

        guard let item = library.activeItem else {
            refreshSettingsModel()
            showAlert("Video yok", "Önce kütüphaneye bir video ekle.")
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
                "Kilit ekranı ayarlanamadı",
                "macOS duvar kağıdı deposu yazılamadı. Sistem Ayarları > Duvar Kağıdı bölümünden tekrar deneyebilirsin."
            )
        }
    }

    private func setMuted(_ muted: Bool) {
        config.muted = muted
        saveConfig()
        players.forEach { $0.isMuted = muted }
        refreshSettingsModel()
        appLog("Muted: \(muted)")
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

        _ = AerialsManager.shared.remove()
        config.lockScreenVideo = false
        config.video = "wallpaper.mp4"
        lockMenuItem?.state = .off
        saveConfig()

        library.removeAll()
        videoURL = supportDirectory.appendingPathComponent("wallpaper.mp4")
        teardownWindows()
        updateMenuStates()
        refreshSettingsModel()
        setStatusIcon(warning: false)
        appLog("Library cleared; previous wallpaper restored")
    }

    @objc private func reloadWallpaper() {
        loadConfig()

        if let activeURL = library.bootstrap(currentVideoURL: videoURL) {
            videoURL = activeURL
            if let item = library.activeItem {
                config.video = "library/\(item.file)"
                saveConfig()
            }
        }

        updateMenuStates()
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
        windows.forEach { $0.orderOut(nil) }
    }

    private func showWindows() {
        windows.forEach { $0.orderFrontRegardless() }
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

        if windows.isEmpty {
            if FileManager.default.fileExists(atPath: videoURL.path) {
                rebuildWindows()
            }
            return
        }

        for (index, window) in windows.enumerated() {
            if index < NSScreen.screens.count {
                let frame = NSScreen.screens[index].frame
                if window.frame != frame {
                    window.setFrame(frame, display: true)
                }
            }
            if !window.isVisible {
                window.orderFrontRegardless()
            }
        }
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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments

if arguments.contains("--uninstall") || arguments.contains("--remove-lock-screen") {
    _ = AerialsManager.shared.remove()
    exit(0)
}

if let index = arguments.firstIndex(of: "--install-lock-screen"), index + 1 < arguments.count {
    let url = URL(fileURLWithPath: arguments[index + 1])
    exit(AerialsManager.shared.install(videoURL: url, force: true) ? 0 : 1)
}

let application = NSApplication.shared
let delegate = WallpaperAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
