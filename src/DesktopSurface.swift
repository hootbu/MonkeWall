import AppKit
import AVFoundation

extension NSScreen {
    var displayKey: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else {
            return localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

final class LoopingPlayer {
    let player = AVQueuePlayer()

    private let looper: AVPlayerLooper
    private var statusObservation: NSKeyValueObservation?

    init(url: URL, onFailure: @escaping (Error?) -> Void) {
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        statusObservation = looper.observe(\.status, options: [.new]) { observed, _ in
            guard observed.status == .failed else { return }
            let error = observed.error
            DispatchQueue.main.async { onFailure(error) }
        }
    }

    deinit {
        player.pause()
    }
}

final class DesktopSurface {
    private static let fadeDuration: CFTimeInterval = 0.8
    private static let firstFrameTimeout: TimeInterval = 2

    let window: NSWindow
    let screenKey: String

    private(set) var videoURL: URL?

    private var currentLayer: AVPlayerLayer?
    private var outgoingLayer: AVPlayerLayer?
    private var outgoingURL: URL?
    private var readyObservation: NSKeyValueObservation?

    var isVisible: Bool { window.occlusionState.contains(.visible) }
    var isFading: Bool { outgoingLayer != nil }

    init(screen: NSScreen, level: NSWindow.Level) {
        screenKey = screen.displayKey

        let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView.wantsLayer = true

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.setFrame(screen.frame, display: true)
    }

    func uses(_ url: URL) -> Bool {
        videoURL == url || outgoingURL == url
    }

    func show(_ player: AVPlayer, url: URL, animated: Bool, completion: @escaping () -> Void) {
        guard let root = window.contentView?.layer else { return }

        settleFade()

        let incoming = AVPlayerLayer(player: player)
        incoming.videoGravity = .resizeAspectFill
        incoming.frame = root.bounds
        incoming.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let outgoing = currentLayer
        let previousURL = videoURL
        currentLayer = incoming
        videoURL = url

        guard animated, let outgoing else {
            outgoing?.removeFromSuperlayer()
            root.addSublayer(incoming)
            completion()
            return
        }

        outgoingLayer = outgoing
        outgoingURL = previousURL

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.opacity = 0
        root.addSublayer(incoming)
        CATransaction.commit()

        let begin: () -> Void = { [weak self] in
            self?.beginFade(to: incoming, completion: completion)
        }
        readyObservation = incoming.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async(execute: begin)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameTimeout, execute: begin)
    }

    private func beginFade(to incoming: AVPlayerLayer, completion: @escaping () -> Void) {
        guard currentLayer === incoming, readyObservation != nil else { return }
        readyObservation = nil

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeDuration)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.currentLayer === incoming else { return }
            self.clearOutgoing()
            completion()
        }
        incoming.opacity = 1
        CATransaction.commit()
    }

    private func settleFade() {
        readyObservation = nil
        clearOutgoing()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentLayer?.opacity = 1
        CATransaction.commit()
    }

    private func clearOutgoing() {
        outgoingLayer?.removeFromSuperlayer()
        outgoingLayer = nil
        outgoingURL = nil
    }
}
