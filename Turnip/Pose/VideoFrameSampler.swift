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
/// is both slower and less frame-accurate during fast motion), keeping ~`sampleRate` frames per
/// second of footage per docs/DESIGN.md's pipeline step 2.
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
/// A `Sendable` struct rather than a class: `FrameSampling` requires `Sendable` so
/// `ProcessingPipeline`, itself `Sendable`, can carry the sampler from the `@MainActor` processing
/// view model into its nonisolated `run`. With no mutable state there is nothing to protect.
struct VideoFrameSampler: Sendable {
    /// The shipped default samples per second of footage, independent of the source frame rate
    /// (docs/DESIGN.md "Performance targets"). At 30 fps this is a stride of 3; at the 240 fps
    /// slo-mo the design doc recommends as the recording mode, a fixed stride of 3 would run 80
    /// inferences per second of footage — 8x the intended sample rate, for no accuracy benefit.
    /// The Settings screen's granularity control (`TurnipSettings.analysisGranularity`, 1...30)
    /// overrides this per instance via `sampleRate` below; this constant stays the default and
    /// the fallback for every call site that doesn't read settings (tests, for one).
    static let targetSamplesPerSecond = 10

    /// Samples per second of footage this instance targets, independent of the source frame
    /// rate. Defaults to `targetSamplesPerSecond`.
    let sampleRate: Int

    init(sampleRate: Int = VideoFrameSampler.targetSamplesPerSecond) {
        self.sampleRate = sampleRate
    }

    /// Maps a track's nominal frame rate to the decode stride that yields ~`sampleRate` samples
    /// per second of footage. A pure static function (rather than inline math, and rather than
    /// an instance method) so the fps→stride mapping is unit-testable without a video file or an
    /// instance.
    static func stride(forNominalFrameRate nominalFrameRate: Float, sampleRate: Int = targetSamplesPerSecond) -> Int {
        guard nominalFrameRate > 0 else {
            // The track doesn't declare a rate (nominalFrameRate == 0): assume a 30 fps
            // baseline instead of sampling every frame or dividing by zero, but still honor
            // `sampleRate` — a hardcoded `3` here would silently ignore the configured
            // granularity for exactly the tracks (VFR, re-encoded) most likely to hit this path.
            return max(1, Int((30.0 / Double(sampleRate)).rounded()))
        }
        return max(1, Int((Double(nominalFrameRate) / Double(sampleRate)).rounded()))
    }

    /// Decodes `asset` and invokes `handler` once per kept frame, sequentially, off the main actor.
    ///
    /// Takes the `AVURLAsset` itself, not just its URL: for Photos-library videos the object
    /// PhotoKit returned is what carries read access to the file, and opening a fresh asset on the
    /// bare path is not guaranteed to work. `SelectedVideo` hands that object straight through.
    ///
    /// `handler` is `@Sendable` on purpose: a non-`Sendable` closure formed inside a `@MainActor`
    /// context (a view model's, say) inherits that isolation, and every call to it would
    /// hop back onto the main thread — putting per-frame inference on the UI thread. `@Sendable`
    /// breaks that inheritance so the handler runs on the generic executor alongside decoding, and
    /// callers must hop to `MainActor` explicitly for any UI-bound writes.
    func sampleFrames(from asset: AVURLAsset, handler: @Sendable (SampledFrame) async throws -> Void) async throws {
        let source = try await CompositionSource(asset: asset)

        // Sample ~`sampleRate` frames/sec of footage regardless of source fps: a fixed stride of
        // 3 matches the shipped default (10/sec) only at 30 fps, and at 240 fps slo-mo it would
        // run 8x the intended inferences per second of footage.
        let sampleStride = Self.stride(forNominalFrameRate: source.nominalFrameRate, sampleRate: sampleRate)

        let (reader, trackOutput) = try source.startReading()
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
                frameIndex: frameIndex, timestamp: timestamp, pixelBuffer: pixelBuffer,
                renderSize: source.renderSize))
        }

        if reader.status == .failed {
            throw PoseError.videoLoadFailed(underlying: reader.error)
        }
    }

    /// Wanted times no further apart than this are read by one reader rather than one each.
    static let spanJoinGap: TimeInterval = 1

    /// Slack for a frame whose timestamp rounds to a hair before the time it was wanted for. Far
    /// under half a frame at 240 fps, so it never admits the frame before.
    static let wantedTimeTolerance: TimeInterval = 1e-4

    /// Decodes only around `times` (file seconds, ascending) and invokes `handler` once per
    /// wanted time with the first frame at or after it; a frame that is first for several, as
    /// when the capture is slower than the sample rate, is handed over once. A time at or past
    /// the end of the asset has no frame and is skipped. Processing's backfill (`PoseBackfill`)
    /// reads the gaps in a take's live pose frames with this instead of decoding the whole take.
    ///
    /// `frameIndex` is the frame's position on the composition grid, since a reader started
    /// mid-file never sees the frames before it. Times within `spanJoinGap` of each other share
    /// one reader: a reader started mid-file decodes forward from the keyframe before its start,
    /// so one reader per time would pay that for every sample of a stretch sampled at the halved
    /// thermal rate, which is a gap every 0.2 s.
    func sampleFrames(
        from asset: AVURLAsset, at times: [TimeInterval],
        handler: @Sendable (SampledFrame) async throws -> Void
    ) async throws {
        let source = try await CompositionSource(asset: asset)
        let inAsset = times.filter { $0 >= 0 && $0 < source.duration.seconds }
        for span in Self.spans(of: inAsset, joiningWithin: Self.spanJoinGap) {
            let (reader, trackOutput) = try source.startReading(in: source.readRange(covering: span))
            var pending = span[...]
            while let wanted = pending.first, let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                guard timestamp >= wanted - Self.wantedTimeTolerance else { continue }
                pending = pending.drop { $0 <= timestamp + Self.wantedTimeTolerance }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                try await handler(SampledFrame(
                    frameIndex: Int((timestamp / source.frameDuration.seconds).rounded()),
                    timestamp: timestamp, pixelBuffer: pixelBuffer, renderSize: source.renderSize))
            }
            if reader.status == .failed {
                throw PoseError.videoLoadFailed(underlying: reader.error)
            }
            reader.cancelReading()
        }
    }

    /// `times` (ascending) split wherever two neighbours are more than `gap` apart.
    static func spans(of times: [TimeInterval], joiningWithin gap: TimeInterval) -> [[TimeInterval]] {
        var spans: [[TimeInterval]] = []
        for time in times {
            if let previous = spans.last?.last, time - previous <= gap {
                spans[spans.count - 1].append(time)
            } else {
                spans.append([time])
            }
        }
        return spans
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

private extension VideoFrameSampler {
    /// The upright composition `asset` is rendered through, built once per call and shared by
    /// every reader that call starts.
    struct CompositionSource {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let composition: AVMutableVideoComposition
        /// The composition grid frames are rendered onto, in display orientation.
        let renderSize: CGSize
        let nominalFrameRate: Float
        /// The composition's output grid spacing.
        let frameDuration: CMTime
        let duration: CMTime

        init(asset: AVURLAsset) async throws {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw PoseError.videoLoadFailed(underlying: nil)
            }
            self.asset = asset
            self.track = track
            nominalFrameRate = try await track.load(.nominalFrameRate)
            duration = try await asset.load(.duration)

            // iPhone portrait videos are stored as landscape-encoded buffers with a 90°
            // preferredTransform, so frames have to be rendered through a video composition that
            // applies it.
            let preferredTransform = try await track.load(.preferredTransform)
            let naturalSize = try await track.load(.naturalSize)
            let geometry = VideoTrackGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform)
            renderSize = geometry.displayedSize
            frameDuration = try await VideoFrameSampler.compositionFrameDuration(of: track)

            composition = AVMutableVideoComposition()
            composition.renderSize = renderSize
            composition.frameDuration = frameDuration
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layerInstruction.setTransform(geometry.uprightTransform, at: .zero)
            instruction.layerInstructions = [layerInstruction]
            composition.instructions = [instruction]
        }

        /// From one frame before the span's first time, so a frame that rounds to just before it
        /// is not cut off, to two frames past its last, enough to reach the first frame at or
        /// after it. Clamped to the asset.
        func readRange(covering span: [TimeInterval]) -> CMTimeRange {
            let timescale: CMTimeScale = 600_000
            let first = CMTime(seconds: span.first ?? 0, preferredTimescale: timescale)
            let last = CMTime(seconds: span.last ?? 0, preferredTimescale: timescale)
            let start = CMTimeMaximum(.zero, CMTimeSubtract(first, frameDuration))
            let end = CMTimeMinimum(duration, CMTimeAdd(last, CMTimeMultiply(frameDuration, multiplier: 2)))
            return CMTimeRange(start: start, end: end)
        }

        /// A started reader over `timeRange`, or the whole asset when nil. The reader is returned
        /// with its output because the output stops delivering once its reader is released.
        func startReading(
            in timeRange: CMTimeRange? = nil
        ) throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
            let reader = try AVAssetReader(asset: asset)
            if let timeRange {
                reader.timeRange = timeRange
            }
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let trackOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: [track], videoSettings: outputSettings)
            trackOutput.videoComposition = composition
            trackOutput.alwaysCopiesSampleData = false

            guard reader.canAdd(trackOutput) else {
                throw PoseError.videoLoadFailed(underlying: nil)
            }
            reader.add(trackOutput)

            guard reader.startReading() else {
                throw PoseError.videoLoadFailed(underlying: reader.error)
            }
            return (reader, trackOutput)
        }
    }
}
