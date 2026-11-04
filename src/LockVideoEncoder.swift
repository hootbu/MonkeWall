import AVFoundation
import VideoToolbox

final class LockVideoEncoder: @unchecked Sendable {
    private static let renderSize = CGSize(width: 3840, height: 2160)
    private static let frameDuration = CMTime(value: 1001, timescale: 60000)
    private static let outputSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: Int(renderSize.width),
        AVVideoHeightKey: Int(renderSize.height),
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 20_000_000,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            AVVideoExpectedSourceFrameRateKey: 60
        ]
    ]

    private let queue = DispatchQueue(label: "com.hootbu.monkewall.encoder", qos: .utility)
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var completion: ((Bool) -> Void)?
    private var isFinishing = false
    private var frameIndex: CMTimeValue = 0
    private var heldSample: CMSampleBuffer?
    private var upcomingSample: CMSampleBuffer?

    func start(source: URL, destination: URL, completion: @escaping (Bool) -> Void) {
        queue.async {
            self.completion = completion
            self.run(source: source, destination: destination)
        }
    }

    func cancel() {
        queue.async {
            guard !self.isFinishing else { return }
            self.reader?.cancelReading()
            self.writer?.cancelWriting()
            self.finish(false)
        }
    }

    private func run(source: URL, destination: URL) {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: destination, fileType: .mov) else {
            finish(false)
            return
        }

        let range = CMTimeRange(start: .zero, end: track.timeRange.end)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ]
        )
        output.videoComposition = composition(for: track, range: range)
        output.alwaysCopiesSampleData = false

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        guard reader.canAdd(output), writer.canAdd(input) else {
            finish(false)
            return
        }
        reader.timeRange = range
        reader.add(output)
        writer.add(input)
        writer.shouldOptimizeForNetworkUse = true

        guard reader.startReading(), writer.startWriting() else {
            appLog("Lock encoder could not start: \(String(describing: reader.error ?? writer.error))")
            reader.cancelReading()
            finish(false)
            return
        }
        writer.startSession(atSourceTime: .zero)
        self.reader = reader
        self.writer = writer
        upcomingSample = output.copyNextSampleBuffer()

        input.requestMediaDataWhenReady(on: queue) {
            while self.completion != nil, !self.isFinishing, input.isReadyForMoreMediaData {
                let wrote = autoreleasepool {
                    self.writeNextFrame(from: output, to: adaptor, end: range.end)
                }
                if !wrote {
                    self.conclude(input: input, reader: reader, writer: writer)
                    return
                }
            }
        }
    }

    private func writeNextFrame(
        from output: AVAssetReaderOutput,
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        end: CMTime
    ) -> Bool {
        let time = CMTimeMultiply(Self.frameDuration, multiplier: Int32(frameIndex))
        guard time < end else { return false }

        while let candidate = upcomingSample,
              heldSample == nil || CMSampleBufferGetPresentationTimeStamp(candidate) <= time {
            heldSample = candidate
            upcomingSample = output.copyNextSampleBuffer()
        }

        guard let heldSample, let buffer = CMSampleBufferGetImageBuffer(heldSample) else { return false }
        frameIndex += 1
        return adaptor.append(buffer, withPresentationTime: time)
    }

    private func conclude(input: AVAssetWriterInput, reader: AVAssetReader, writer: AVAssetWriter) {
        guard reader.status != .failed, frameIndex > 0, writer.status == .writing else {
            appLog("Lock encoder failed: \(String(describing: reader.error ?? writer.error))")
            reader.cancelReading()
            writer.cancelWriting()
            finish(false)
            return
        }

        reader.cancelReading()
        heldSample = nil
        upcomingSample = nil
        isFinishing = true
        input.markAsFinished()
        writer.finishWriting {
            self.queue.async { self.finish(writer.status == .completed) }
        }
    }

    private func finish(_ succeeded: Bool) {
        completion?(succeeded)
        completion = nil
    }

    private func composition(for track: AVAssetTrack, range: CMTimeRange) -> AVVideoComposition {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(fillTransform(for: track), at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = Self.renderSize
        composition.frameDuration = Self.frameDuration
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.instructions = [instruction]
        return composition
    }

    private func fillTransform(for track: AVAssetTrack) -> CGAffineTransform {
        let render = Self.renderSize
        let box = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        let scale = max(render.width / box.width, render.height / box.height)

        return track.preferredTransform
            .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (render.width - box.width * scale) / 2,
                y: (render.height - box.height * scale) / 2
            ))
    }
}
