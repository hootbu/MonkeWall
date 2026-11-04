import AppKit
import SwiftUI

// MARK: - Model

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case library
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .library: return L("Library")
        case .about: return L("About")
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .library: return "film.stack"
        case .about: return "info.circle"
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
    @Published var pauseWhenAppActive: Bool
    @Published var lockScreenVideo: Bool
    @Published var muted: Bool
    @Published var pauseOnBattery: Bool
    @Published var launchAtLogin = false
    @Published var automaticUpdateChecks = false
    @Published var rotationMinutes = 0
    @Published var rotationShuffle = false
    @Published var libraryCount: Int
    @Published var librarySizeText: String
    @Published var libraryPath: String

    init(
        pauseWhenAppActive: Bool,
        lockScreenVideo: Bool,
        muted: Bool,
        pauseOnBattery: Bool,
        libraryCount: Int,
        librarySizeText: String,
        libraryPath: String
    ) {
        self.pauseWhenAppActive = pauseWhenAppActive
        self.lockScreenVideo = lockScreenVideo
        self.muted = muted
        self.pauseOnBattery = pauseOnBattery
        self.libraryCount = libraryCount
        self.librarySizeText = librarySizeText
        self.libraryPath = libraryPath
    }

    var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return String(format: L("Version %@ (%@)"), version, build)
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    let onPauseChange: (Bool) -> Void
    let onLockScreenChange: (Bool) -> Void
    let onMuteChange: (Bool) -> Void
    let onBatteryPauseChange: (Bool) -> Void
    let onLaunchAtLoginChange: (Bool) -> Void
    let onAutomaticUpdatesChange: (Bool) -> Void
    let onRotationChange: (Int) -> Void
    let onShuffleChange: (Bool) -> Void
    let onUninstall: () -> Void
    let onOpenLibrary: () -> Void
    let onRevealLibraryFolder: () -> Void
    let onDeleteAll: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var showUninstallConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1)

            ScrollView {
                content
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(BrandTheme.background)
        .frame(minWidth: 660, minHeight: 480)
        .alert("Delete All Videos?", isPresented: $showDeleteConfirmation) {
            Button("Delete All", role: .destructive) {
                onDeleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All library videos, thumbnails and 4K lock screen copies will be deleted, and your previous wallpaper will come back. This can't be undone.")
        }
        .alert("Uninstall MonkeWall?", isPresented: $showUninstallConfirmation) {
            Button("Uninstall", role: .destructive) {
                onUninstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your previous wallpaper comes back, all videos and settings are deleted, and the app moves to the Trash. This can't be undone.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "play.square.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BrandTheme.accent)
                Text("MonkeWall")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(BrandTheme.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ForEach(SettingsTab.allCases) { tab in
                Button {
                    model.selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .frame(width: 18)
                        Text(tab.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        model.selectedTab == tab
                            ? BrandTheme.primaryText
                            : BrandTheme.secondaryText
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        model.selectedTab == tab
                            ? Color.white.opacity(0.08)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(model.versionText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(BrandTheme.secondaryText)
                .padding(12)
        }
        .frame(width: 176)
        .background(BrandTheme.sidebar)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case .general:
            generalTab
        case .library:
            libraryTab
        case .about:
            aboutTab
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader(
                "General",
                "Set how MonkeWall behaves."
            )

            VStack(spacing: 0) {
                settingRow(
                    title: "Launch at login",
                    subtitle: "Starts MonkeWall when you log in to your Mac.",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { value in
                            model.launchAtLogin = value
                            onLaunchAtLoginChange(value)
                        }
                    )
                )

                sectionDivider

                settingRow(
                    title: "Check for updates automatically",
                    subtitle: "Looks for a new version once a day and asks before installing.",
                    isOn: Binding(
                        get: { model.automaticUpdateChecks },
                        set: { value in
                            model.automaticUpdateChecks = value
                            onAutomaticUpdatesChange(value)
                        }
                    )
                )

                sectionDivider

                settingRow(
                    title: "Pause when another app is active",
                    subtitle: "Pauses the video whenever another app is in front, even if the desktop is still visible. When off, it only pauses once the desktop is completely covered.",
                    isOn: Binding(
                        get: { model.pauseWhenAppActive },
                        set: { value in
                            model.pauseWhenAppActive = value
                            onPauseChange(value)
                        }
                    )
                )

                sectionDivider

                settingRow(
                    title: "Play on lock screen",
                    subtitle: "Applies the selected video to the macOS lock screen and screen saver.",
                    isOn: Binding(
                        get: { model.lockScreenVideo },
                        set: { value in
                            model.lockScreenVideo = value
                            onLockScreenChange(value)
                        }
                    )
                )

                sectionDivider

                settingRow(
                    title: "Mute",
                    subtitle: "Turns off video sound.",
                    isOn: Binding(
                        get: { model.muted },
                        set: { value in
                            model.muted = value
                            onMuteChange(value)
                        }
                    )
                )

                sectionDivider

                settingRow(
                    title: "Pause on battery",
                    subtitle: "Pauses the video while on battery or in Low Power Mode.",
                    isOn: Binding(
                        get: { model.pauseOnBattery },
                        set: { value in
                            model.pauseOnBattery = value
                            onBatteryPauseChange(value)
                        }
                    )
                )
            }
            .background(cardBackground)

            VStack(spacing: 0) {
                rotationRow

                sectionDivider

                settingRow(
                    title: "Shuffle",
                    subtitle: "Picks a random video instead of following library order.",
                    isOn: Binding(
                        get: { model.rotationShuffle },
                        set: { value in
                            model.rotationShuffle = value
                            onShuffleChange(value)
                        }
                    )
                )
                .disabled(model.rotationMinutes == 0)
                .opacity(model.rotationMinutes == 0 ? 0.45 : 1)
            }
            .background(cardBackground)

            Text("Each video is re-encoded to 4K HEVC for the lock screen. This can take a few seconds depending on its length.")
                .font(.system(size: 11))
                .foregroundStyle(BrandTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var libraryTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader(
                "Library",
                "Videos and lock screen copies are stored here."
            )

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(videoCountText(model.libraryCount))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(BrandTheme.primaryText)
                        Text(model.librarySizeText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(BrandTheme.secondaryText)
                    }

                    Spacer()

                    Button("Open Library", action: onOpenLibrary)
                        .buttonStyle(PrimarySettingsButtonStyle())
                }

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 7) {
                    Text("FOLDER")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(BrandTheme.secondaryText)

                    Text(model.libraryPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(BrandTheme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack(spacing: 12) {
                        Button("Show in Finder", action: onRevealLibraryFolder)
                            .buttonStyle(SecondarySettingsButtonStyle())

                        Text("The 4K lock screen copies are in this folder too.")
                            .font(.system(size: 10))
                            .foregroundStyle(BrandTheme.secondaryText)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(18)
            .background(cardBackground)

            VStack(alignment: .leading, spacing: 10) {
                Text("DANGER ZONE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(BrandTheme.danger)

                Text("Deletes all library videos, thumbnails and 4K lock screen copies. Your previous wallpaper comes back.")
                    .font(.system(size: 11))
                    .foregroundStyle(BrandTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete all videos", systemImage: "trash")
                }
                .buttonStyle(DangerSettingsButtonStyle())
                .disabled(model.libraryCount == 0)
                .opacity(model.libraryCount == 0 ? 0.45 : 1)
                .padding(.top, 2)
            }
            .padding(18)
            .background(
                Color.red.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
            }

            Spacer(minLength: 0)
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .shadow(color: Color.black.opacity(0.4), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 5) {
                    Text("MonkeWall")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(BrandTheme.primaryText)

                    Text(model.versionText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BrandTheme.secondaryText)

                    Text("Live wallpaper for macOS")
                        .font(.system(size: 12))
                        .foregroundStyle(BrandTheme.secondaryText)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                infoRow("Developer", "Emir Yorgun (hootbu)")
                infoRow("Copyright", L("© 2026 Emir Yorgun. All rights reserved."))
                infoRow("License", L("All rights reserved. Commercial distribution requires permission."))
                infoRow("System", ProcessInfo.processInfo.operatingSystemVersionString)
            }

            Text("MonkeWall was built for personal use. Videos and lock screen copies are stored only on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(BrandTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showUninstallConfirmation = true
            } label: {
                Label("Uninstall MonkeWall…", systemImage: "trash")
            }
            .buttonStyle(DangerSettingsButtonStyle())

            Spacer(minLength: 0)
        }
    }

    // MARK: Components

    private var rotationRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Change video automatically")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandTheme.primaryText)
                Text("Moves to the next video at this interval. Screens with their own video stay as they are.")
                    .font(.system(size: 11))
                    .foregroundStyle(BrandTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker("", selection: Binding(
                get: { model.rotationMinutes },
                set: { value in
                    model.rotationMinutes = value
                    onRotationChange(value)
                }
            )) {
                Text("Off").tag(0)
                Text("15 minutes").tag(15)
                Text("1 hour").tag(60)
                Text("6 hours").tag(360)
                Text("Every day").tag(1440)
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(14)
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
    }

    private func pageHeader(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(BrandTheme.primaryText)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(BrandTheme.secondaryText)
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    private func settingRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandTheme.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(BrandTheme.accent)
        }
        .padding(14)
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BrandTheme.secondaryText)
                .frame(width: 104, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(BrandTheme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(
        model: SettingsModel,
        onPauseChange: @escaping (Bool) -> Void,
        onLockScreenChange: @escaping (Bool) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onBatteryPauseChange: @escaping (Bool) -> Void,
        onLaunchAtLoginChange: @escaping (Bool) -> Void,
        onAutomaticUpdatesChange: @escaping (Bool) -> Void,
        onRotationChange: @escaping (Int) -> Void,
        onShuffleChange: @escaping (Bool) -> Void,
        onUninstall: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void,
        onRevealLibraryFolder: @escaping () -> Void,
        onDeleteAll: @escaping () -> Void
    ) {
        let view = SettingsView(
            model: model,
            onPauseChange: onPauseChange,
            onLockScreenChange: onLockScreenChange,
            onMuteChange: onMuteChange,
            onBatteryPauseChange: onBatteryPauseChange,
            onLaunchAtLoginChange: onLaunchAtLoginChange,
            onAutomaticUpdatesChange: onAutomaticUpdatesChange,
            onRotationChange: onRotationChange,
            onShuffleChange: onShuffleChange,
            onUninstall: onUninstall,
            onOpenLibrary: onOpenLibrary,
            onRevealLibraryFolder: onRevealLibraryFolder,
            onDeleteAll: onDeleteAll
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = L("MonkeWall Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 730))
        window.minSize = NSSize(width: 660, height: 480)
        window.center()
        window.setFrameAutosaveName("MonkeWallSettingsWindow")

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Button styles

private struct PrimarySettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                BrandTheme.accent.opacity(configuration.isPressed ? 0.75 : 1),
                in: Capsule()
            )
            .foregroundStyle(Color.black.opacity(0.85))
    }
}

private struct SecondarySettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.11 : 0.07),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .foregroundStyle(BrandTheme.primaryText)
    }
}

private struct DangerSettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                BrandTheme.danger.opacity(configuration.isPressed ? 0.2 : 0.12),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(BrandTheme.danger.opacity(0.3), lineWidth: 1)
            }
            .foregroundStyle(BrandTheme.danger)
    }
}
