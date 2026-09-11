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
    /// Frames are kept 1-in-N. The processing pipeline divides a track's frame count by this
    /// to estimate its progress denominator, so the two have to read the same number.
    static let sampleStride = 3

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
            throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
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
            // Decoding a multi-minute clip outlives the screen that asked for it unless the loop
            // itself gives up: nothing else here suspends at a cancellation point.
            try Task.checkCancellation()
            defer { frameIndex += 1 }
            guard frameIndex % Self.sampleStride == 0 else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            try await handler(SampledFrame(frameIndex: frameIndex, timestamp: timestamp, pixelBuffer: pixelBuffer))
        }

        if reader.status == .failed {
            throw PoseDiagnosticError.videoLoadFailed(underlying: reader.error)
        }
    }
}
