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
    /// The composition grid the frame was rendered onto, in display orientation. The sampler
    /// applies the track's `preferredTransform` when rendering, so on a portrait iPhone clip
    /// this is the transpose of the track's `naturalSize`. Keypoints measured against the pixel
    /// buffer live in this space; mapping them back to source-frame coordinates needs this size
    /// plus the track's `preferredTransform`.
    let renderSize: CGSize
}

/// Decodes video frames via AVAssetReader (not AVAssetImageGenerator, which reseeks per-frame and
/// is both slower and less frame-accurate during fast motion), keeping every 3rd frame per
/// docs/DESIGN.md's pipeline step 2.
///
/// Frames are rendered through an `AVMutableVideoComposition` that applies the track's
/// `preferredTransform`. The composition output's `frameDuration` defines a uniform output grid:
/// one frame is emitted per source sample, at the first grid position at or after that sample's
/// own presentation time. With `frameDuration = minFrameDuration` no frame is dropped, but
/// per-frame Δt is quantized to the grid — a source timestamp that is not a multiple of it is
/// reported late, and a steady variable-frame-rate stretch (an iPhone lowers the rate in dim
/// light) can read back as an alternating stutter. So `frameIndex` counts source samples in
/// emission order, but `timestamp` is a grid position rather than the track's own presentation
/// timestamp, and any future consumer that divides displacement by Δt must tolerate up to one
/// frame duration of lateness.
///
/// A `Sendable` struct rather than a class: it is owned by a `@MainActor` view model but
/// `sampleFrames` is nonisolated, so every call sends the sampler out of the main actor. With no
/// mutable state there is nothing to protect, and being `Sendable` keeps that crossing legal under
/// strict concurrency (Swift 6 would otherwise report "sending 'self.sampler' risks causing data
/// races").
struct VideoFrameSampler: Sendable {
    /// Samples per second of footage, independent of the source frame rate (docs/DESIGN.md
    /// "Performance targets"). At 30 fps this reproduces the old hardcoded stride of 3; at the
    /// 240 fps slo-mo the design doc recommends as the recording mode, a fixed stride of 3 would
    /// have run 80 inferences per second of footage — 8x the intended sample rate, for no
    /// accuracy benefit.
    static let targetSamplesPerSecond = 10

    /// Maps a track's nominal frame rate to the decode stride that yields ~`targetSamplesPerSecond`
    /// samples per second of footage. A pure function (rather than inline math) so the fps→stride
    /// mapping is unit-testable without a video file.
    static func stride(forNominalFrameRate nominalFrameRate: Float) -> Int {
        guard nominalFrameRate > 0 else {
            // The track doesn't declare a rate (nominalFrameRate == 0): keep the old 30 fps
            // behavior instead of sampling every frame or dividing by zero.
            return 3
        }
        return max(1, Int((Double(nominalFrameRate) / Double(targetSamplesPerSecond)).rounded()))
    }

    /// Decodes `asset` and invokes `handler` once per kept frame, sequentially, off the main actor.
    ///
    /// Takes the `AVURLAsset` itself, not just its URL: for Photos-library videos the object
    /// PhotoKit returned is what carries read access to the file, and opening a fresh asset on the
    /// bare path is not guaranteed to work. `SelectedVideo` hands that object straight through.
    ///
    /// `handler` is `@Sendable` on purpose: a non-`Sendable` closure formed inside a `@MainActor`
    /// context (e.g. `PoseDiagnosticViewModel`) inherits that isolation, and every call to it would
    /// hop back onto the main thread — putting per-frame inference on the UI thread. `@Sendable`
    /// breaks that inheritance so the handler runs on the generic executor alongside decoding, and
    /// callers must hop to `MainActor` explicitly for any UI-bound writes.
    func sampleFrames(from asset: AVURLAsset, handler: @Sendable (SampledFrame) async throws -> Void) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseError.videoLoadFailed(underlying: nil)
        }

        // Sample ~10 frames/sec of footage regardless of source fps (issue #21): a fixed stride
        // of 3 matches the design doc only at 30 fps, and at 240 fps slo-mo it would run 8x the
        // intended inferences per second of footage.
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let sampleStride = Self.stride(forNominalFrameRate: nominalFrameRate)

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
            throw PoseError.videoLoadFailed(underlying: nil)
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw PoseError.videoLoadFailed(underlying: reader.error)
        }

        var frameIndex = 0
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            // Decoding a multi-minute clip outlives the screen that asked for it unless the loop
            // itself gives up: nothing else here suspends at a cancellation point.
            try Task.checkCancellation()
            defer { frameIndex += 1 }
            guard frameIndex % sampleStride == 0 else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            try await handler(SampledFrame(
                frameIndex: frameIndex, timestamp: timestamp, pixelBuffer: pixelBuffer, renderSize: renderSize))
        }

        if reader.status == .failed {
            throw PoseError.videoLoadFailed(underlying: reader.error)
        }
    }

    /// The composition's output grid from the track's own timing values. The pure overload below
    /// carries the logic so the throw branch has a test seam — no `AVAssetWriter` fixture can
    /// produce a track with neither a usable `minFrameDuration` nor a nonzero `nominalFrameRate`.
    private static func compositionFrameDuration(of track: AVAssetTrack) async throws -> CMTime {
        let minFrameDuration = try await track.load(.minFrameDuration)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        return try compositionFrameDuration(minFrameDuration: minFrameDuration, nominalFrameRate: nominalFrameRate)
    }

    /// The composition's output grid. `minFrameDuration` is exact and per-track; `nominalFrameRate`
    /// is the fallback and is `0` whenever the rate cannot be determined. With neither there is no
    /// valid grid: an `AVMutableVideoComposition` defaults to a non-numeric `frameDuration`
    /// (`CMTime(value: 0, timescale: 0)`), and assigning it one raises `NSInvalidArgumentException`
    /// ("video composition must have a positive frameDuration") where the composition is attached
    /// to the reader output — uncatchable from Swift, so the process dies instead of failing the
    /// load. Throw `videoLoadFailed` instead, which the app can surface.
    static func compositionFrameDuration(minFrameDuration: CMTime, nominalFrameRate: Float) throws -> CMTime {
        if minFrameDuration.isNumeric && minFrameDuration.seconds > 0 {
            return minFrameDuration
        }
        let roundedFrameRate = nominalFrameRate.rounded()
        // `CMTimeScale` is `Int32`: converting a rate past `Int32.max` traps instead of throwing,
        // so reject it here the same way the guard rejects a rate below 1.
        guard roundedFrameRate >= 1, let timescale = CMTimeScale(exactly: roundedFrameRate) else {
            throw PoseError.videoLoadFailed(underlying: nil)
        }
        return CMTime(value: 1, timescale: timescale)
    }
}
