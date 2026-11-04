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
        case .general: return "Genel"
        case .library: return "Kütüphane"
        case .about: return "Hakkında"
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
    @Published var libraryCount: Int
    @Published var librarySizeText: String
    @Published var libraryPath: String

    init(
        pauseWhenAppActive: Bool,
        lockScreenVideo: Bool,
        muted: Bool,
        libraryCount: Int,
        librarySizeText: String,
        libraryPath: String
    ) {
        self.pauseWhenAppActive = pauseWhenAppActive
        self.lockScreenVideo = lockScreenVideo
        self.muted = muted
        self.libraryCount = libraryCount
        self.librarySizeText = librarySizeText
        self.libraryPath = libraryPath
    }

    var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Sürüm \(version) (\(build))"
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    let onPauseChange: (Bool) -> Void
    let onLockScreenChange: (Bool) -> Void
    let onMuteChange: (Bool) -> Void
    let onOpenLibrary: () -> Void
    let onRevealLibraryFolder: () -> Void
    let onDeleteAll: () -> Void

    @State private var showDeleteConfirmation = false

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
        .alert("Tüm videolar silinsin mi?", isPresented: $showDeleteConfirmation) {
            Button("Tümünü Sil", role: .destructive) {
                onDeleteAll()
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Kütüphanedeki tüm videolar, kapak görselleri ve kilit ekranı için hazırlanan 4K kopyalar silinecek. Duvar kağıdı eski haline dönecek. Bu işlem geri alınamaz.")
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
                "Genel",
                "MonkeWall'un nasıl davranacağını ayarla."
            )

            VStack(spacing: 0) {
                settingRow(
                    title: "Odaklanınca duraklat",
                    subtitle: "Başka bir uygulama öne geldiğinde videoyu duraklatır.",
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
                    title: "Kilit ekranında oynat",
                    subtitle: "Seçili videoyu macOS kilit ekranına ve ekran koruyucuya uygular.",
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
                    title: "Sessiz",
                    subtitle: "Videoların sesini kapatır.",
                    isOn: Binding(
                        get: { model.muted },
                        set: { value in
                            model.muted = value
                            onMuteChange(value)
                        }
                    )
                )
            }
            .background(cardBackground)

            Text("Kilit ekranı için her video 4K HEVC olarak yeniden kodlanır; bu işlem videonun uzunluğuna göre birkaç saniye sürebilir.")
                .font(.system(size: 11))
                .foregroundStyle(BrandTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var libraryTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader(
                "Kütüphane",
                "Videolar ve kilit ekranı kopyaları burada tutulur."
            )

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.libraryCount) video")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(BrandTheme.primaryText)
                        Text(model.librarySizeText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(BrandTheme.secondaryText)
                    }

                    Spacer()

                    Button("Kütüphaneyi Aç", action: onOpenLibrary)
                        .buttonStyle(PrimarySettingsButtonStyle())
                }

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 7) {
                    Text("KLASÖR")
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
                        Button("Finder'da Göster", action: onRevealLibraryFolder)
                            .buttonStyle(SecondarySettingsButtonStyle())

                        Text("4K kilit kopyaları da bu klasörde.")
                            .font(.system(size: 10))
                            .foregroundStyle(BrandTheme.secondaryText)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(18)
            .background(cardBackground)

            VStack(alignment: .leading, spacing: 10) {
                Text("TEHLİKELİ BÖLGE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(BrandTheme.danger)

                Text("Kütüphanedeki tüm videoları, kapak görsellerini ve kilit ekranı için hazırlanan 4K kopyaları siler. Duvar kağıdı eski haline döner.")
                    .font(.system(size: 11))
                    .foregroundStyle(BrandTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showDeleteConfirmation = true
                } label: {
                    Label("Tüm videoları sil", systemImage: "trash")
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

                    Text("macOS için hareketli duvar kağıdı")
                        .font(.system(size: 12))
                        .foregroundStyle(BrandTheme.secondaryText)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                infoRow("Geliştirici", "Emir Yorgun (hootbu)")
                infoRow("Telif hakkı", "© 2026 Emir Yorgun. Tüm hakları saklıdır.")
                infoRow("Lisans", "Tüm hakları saklıdır. Ticari dağıtım için izin gerekir.")
                infoRow("Sistem", ProcessInfo.processInfo.operatingSystemVersionString)
            }

            Text("MonkeWall kişisel kullanım için geliştirilmiştir. Videolar ve kilit ekranı kopyaları yalnızca bu Mac'te saklanır.")
                .font(.system(size: 11))
                .foregroundStyle(BrandTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    // MARK: Components

    private var appIcon: NSImage {
        NSApp.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
    }

    private func pageHeader(_ title: String, _ subtitle: String) -> some View {
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
        title: String,
        subtitle: String,
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

    private func infoRow(_ label: String, _ value: String) -> some View {
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
        onOpenLibrary: @escaping () -> Void,
        onRevealLibraryFolder: @escaping () -> Void,
        onDeleteAll: @escaping () -> Void
    ) {
        let view = SettingsView(
            model: model,
            onPauseChange: onPauseChange,
            onLockScreenChange: onLockScreenChange,
            onMuteChange: onMuteChange,
            onOpenLibrary: onOpenLibrary,
            onRevealLibraryFolder: onRevealLibraryFolder,
            onDeleteAll: onDeleteAll
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "MonkeWall Ayarlar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 520))
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
