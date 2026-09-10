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

/// Decodes video frames at native fps via AVAssetReader (not AVAssetImageGenerator, which
/// reseeks per-frame and is both slower and less frame-accurate during fast motion), keeping
/// every 3rd frame per docs/DESIGN.md's pipeline step 2.
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

        // iPhone portrait videos are stored as landscape-encoded buffers with a 90° preferredTransform.
        // Decoding the raw track would hand every frame to the model rotated 90°. Render through a
        // video composition that applies the transform, so sampled frames match what the user sees.
        let preferredTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        videoComposition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(max(nominalFrameRate.rounded(), 1)))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(preferredTransform, at: .zero)
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
}
