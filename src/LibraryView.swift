import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - View

struct LibraryView: View {
    @ObservedObject var library: WallpaperLibrary

    let onAdd: () -> Void
    let onSelect: (WallpaperItem) -> Void
    let onReveal: (WallpaperItem) -> Void
    let onRemove: (WallpaperItem) -> Void
    let onDropVideos: ([URL]) -> Void

    @State private var isDropTarget = false
    @State private var hoveredID: String?
    @State private var pendingRemoval: WallpaperItem?

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 180, maximum: 260), spacing: 16, alignment: .top),
        count: 3
    )

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            content
        }
        .background(BrandTheme.background)
        .overlay {
            Rectangle()
                .strokeBorder(
                    BrandTheme.accent.opacity(isDropTarget ? 0.9 : 0),
                    lineWidth: 3
                )
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .alert(
            "Videoyu tamamen sil?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Sil", role: .destructive) {
                if let item = pendingRemoval {
                    pendingRemoval = nil
                    onRemove(item)
                }
            }
            Button("Vazgeç", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(pendingRemoval.map { item in
                var message = "\"\(item.title)\" videosu, kapak görseli ve kilit ekranı için hazırlanan 4K kopyası diskten silinecek."
                if library.items.count <= 1 {
                    message += "\n\nBu son video. Silinince duvar kağıdı eski haline dönecek."
                }
                message += "\n\nBu işlem geri alınamaz."
                return message
            } ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kütüphane")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(BrandTheme.primaryText)

                HStack(spacing: 6) {
                    Text("\(library.items.count) video")
                    if library.isImporting {
                        Text("·")
                        Text("ekleniyor…")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrandTheme.secondaryText)
            }

            Spacer()

            if library.isImporting {
                ProgressView()
                    .controlSize(.small)
                    .tint(BrandTheme.accent)
            }

            Button(action: onAdd) {
                Label("Video Ekle", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(BrandTheme.accent, in: Capsule())
                    .foregroundStyle(Color.black.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Bilgisayarından bir veya birden fazla video ekle")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(BrandTheme.sidebar)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(library.items) { item in
                        ZStack(alignment: .topLeading) {
                            VideoCard(
                                item: item,
                                thumbnail: library.thumbnails[item.id],
                                isActive: library.activeID == item.id,
                                isPreparing: library.preparingIDs.contains(item.id),
                                isHovered: hoveredID == item.id
                            )
                            .onTapGesture {
                                onSelect(item)
                            }

                            if hoveredID == item.id {
                                Button {
                                    pendingRemoval = item
                                } label: {
                                    Image(systemName: "trash.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(BrandTheme.danger)
                                        .frame(width: 26, height: 26)
                                        .background(Color.black.opacity(0.66), in: Circle())
                                        .overlay {
                                            Circle()
                                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .help("Videoyu, kapağı ve kilit ekranı kopyasını sil")
                                .padding(8)
                            }
                        }
                        .onHover { hovering in
                            if hovering {
                                hoveredID = item.id
                            } else if hoveredID == item.id {
                                hoveredID = nil
                            }
                        }
                        .contextMenu {
                            Button("Duvar Kağıdı Yap") {
                                onSelect(item)
                            }
                            Button("Finder'da Göster") {
                                onReveal(item)
                            }
                            Divider()
                            Button("Kütüphaneden Kaldır", role: .destructive) {
                                pendingRemoval = item
                            }
                        }
                    }
                }
                .padding(22)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(BrandTheme.accent.opacity(0.85))

            Text("Henüz video yok")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandTheme.primaryText)

            Text("Videolarını bu pencereye sürükle veya Video Ekle'ye bas.")
                .font(.system(size: 13))
                .foregroundStyle(BrandTheme.secondaryText)

            Button(action: onAdd) {
                Label("Video Ekle", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(BrandTheme.accent, in: Capsule())
                    .foregroundStyle(Color.black.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                defer { group.leave() }

                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let value = item as? NSURL {
                    url = value as URL
                } else if let string = item as? String {
                    url = URL(fileURLWithPath: string)
                }

                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            onDropVideos(urls)
        }
        return true
    }
}

// MARK: - Card

private struct VideoCard: View {
    let item: WallpaperItem
    let thumbnail: NSImage?
    let isActive: Bool
    let isPreparing: Bool
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            thumbnailView

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandTheme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if !item.durationText.isEmpty {
                        Text(item.durationText)
                    }
                    if isActive {
                        Text("·")
                        Text("Aktif")
                            .foregroundStyle(BrandTheme.accent)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BrandTheme.secondaryText)
            }
        }
        .padding(9)
        .background(
            Color.white.opacity(isHovered ? 0.065 : 0.03),
            in: RoundedRectangle(cornerRadius: 15)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(
                    Color.white.opacity(isHovered ? 0.12 : 0.05),
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }

    private var thumbnailView: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.white.opacity(0.07))

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(Color.white.opacity(0.22))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    isActive
                        ? BrandTheme.accent
                        : Color.white.opacity(isHovered ? 0.22 : 0.08),
                    lineWidth: isActive ? 2 : 1
                )
        }
        .overlay(alignment: .topTrailing) {
            if isActive {
                Label("Kullanılıyor", systemImage: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(BrandTheme.accent, in: Capsule())
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(7)
            }
        }
        .overlay {
            if isPreparing {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.black.opacity(0.66))
                    VStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Kilit ekranı hazırlanıyor…")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                    }
                }
            }
        }
    }
}

// MARK: - Window

final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    init(
        library: WallpaperLibrary,
        onAdd: @escaping () -> Void,
        onSelect: @escaping (WallpaperItem) -> Void,
        onReveal: @escaping (WallpaperItem) -> Void,
        onRemove: @escaping (WallpaperItem) -> Void,
        onDropVideos: @escaping ([URL]) -> Void
    ) {
        let view = LibraryView(
            library: library,
            onAdd: onAdd,
            onSelect: onSelect,
            onReveal: onReveal,
            onRemove: onRemove,
            onDropVideos: onDropVideos
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "MonkeWall Kütüphanesi"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 580))
        window.minSize = NSSize(width: 620, height: 420)
        window.center()
        window.setFrameAutosaveName("MonkeWallLibraryWindow")

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
