import AVFoundation
import CoreVideo

/// One decoded frame handed to `VideoFrameSampler.sampleFrames`' handler.
///
/// `@unchecked Sendable` because `CVPixelBuffer` has no `Sendable` conformance on this SDK, yet the
/// frame must cross from the sampler's decode loop into the `@Sendable` handler (and from there
/// into the `MoveNetThunderModel` actor). The crossing is safe by construction: each buffer is
/// produced by a single `AVAssetReader` loop, handed to exactly one handler invocation, and the
/// loop `await`s that invocation before decoding the next frame — so no two contexts ever touch
/// the same buffer concurrently. Revisit if the sampler ever fans frames out to parallel consumers.
struct SampledFrame: @unchecked Sendable {
    let frameIndex: Int
    let timestamp: TimeInterval
    let pixelBuffer: CVPixelBuffer
}

/// Decodes video frames via AVAssetReader (not AVAssetImageGenerator, which reseeks per-frame and
/// is both slower and less frame-accurate during fast motion), keeping every 3rd frame per
/// docs/DESIGN.md's pipeline step 2.
///
/// Frames are composed onto a fixed grid at the track's shortest frame duration so the track's
/// `preferredTransform` can be applied, so `frameIndex` and `timestamp` are positions on that grid
/// rather than the source's own presentation timestamps. Variable-frame-rate recordings (an iPhone
/// lowers the rate in dim light) are resampled onto it.
///
/// A `Sendable` struct rather than a class: it is owned by a `@MainActor` view model but
/// `sampleFrames` is nonisolated, so every call sends the sampler out of the main actor. With no
/// mutable state there is nothing to protect, and being `Sendable` keeps that crossing legal under
/// strict concurrency (Swift 6 would otherwise report "sending 'self.sampler' risks causing data
/// races").
struct VideoFrameSampler: Sendable {
    private let sampleStride = 3

    /// Decodes `url` and invokes `handler` once per kept frame, sequentially, off the main actor.
    ///
    /// `handler` is `@Sendable` on purpose: a non-`Sendable` closure formed inside a `@MainActor`
    /// context (e.g. `PoseDiagnosticViewModel`) inherits that isolation, and every call to it would
    /// hop back onto the main thread — putting per-frame inference on the UI thread. `@Sendable`
    /// breaks that inheritance so the handler runs on the generic executor alongside decoding, and
    /// callers must hop to `MainActor` explicitly for any UI-bound writes.
    func sampleFrames(from url: URL, handler: @Sendable (SampledFrame) async throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }

        // iPhone portrait videos are stored as landscape-encoded buffers with a 90° preferredTransform,
        // so frames have to be rendered through a video composition that applies it.
        let preferredTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        // A transform that rotates about the origin puts the content outside [0, renderSize], which
        // composes correctly sized frames of pure background. Camera-roll assets carry the
        // normalizing translation already; imported and edited ones need not.
        let renderTransform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = try await Self.compositionFrameDuration(of: track)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(renderTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track], videoSettings: outputSettings)
        trackOutput.videoComposition = videoComposition
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: reader.error)
        }

        var frameIndex = 0
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            defer { frameIndex += 1 }
            guard frameIndex % sampleStride == 0 else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            try await handler(SampledFrame(frameIndex: frameIndex, timestamp: timestamp, pixelBuffer: pixelBuffer))
        }

        if reader.status == .failed {
            throw PoseDiagnosticError.videoLoadFailed(underlying: reader.error)
        }
    }

    /// The composition's output grid. `minFrameDuration` is exact and per-track; `nominalFrameRate`
    /// is the fallback and is `0` whenever the rate cannot be determined. With neither, an
    /// `AVMutableVideoComposition` defaults to one composed frame per second — too few samples for
    /// the peak detection in docs/DESIGN.md step 5 to find anything, and it reports no error, so the
    /// clip reads as trickless rather than unreadable. Fail the load instead.
    private static func compositionFrameDuration(of track: AVAssetTrack) async throws -> CMTime {
        let minFrameDuration = try await track.load(.minFrameDuration)
        if minFrameDuration.isNumeric && minFrameDuration.seconds > 0 {
            return minFrameDuration
        }
        let roundedFrameRate = try await track.load(.nominalFrameRate).rounded()
        guard roundedFrameRate >= 1 else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }
        return CMTime(value: 1, timescale: CMTimeScale(roundedFrameRate))
    }
}
