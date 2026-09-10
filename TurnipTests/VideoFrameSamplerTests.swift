import AVFoundation
import CoreVideo
import XCTest
@testable import Turnip

/// Records what the sampler's handler observed. An actor (rather than a captured `var`) because the
/// handler is `@Sendable` and may not mutate captured state directly.
private actor FrameObservations {
    struct Entry: Equatable {
        let frameIndex: Int
        let onMainThread: Bool
    }

    private(set) var entries: [Entry] = []

    func record(_ entry: Entry) {
        entries.append(entry)
    }
}

/// `@MainActor` on purpose: this mirrors `PoseDiagnosticViewModel`, where the handler closure is
/// formed inside a MainActor context. That is exactly the shape in which a non-`@Sendable` handler
/// would inherit MainActor isolation and run per-frame work on the UI thread.
@MainActor
final class VideoFrameSamplerTests: XCTestCase {
    private var videoURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        videoURL = try await Self.writeTestVideo(frameCount: 10, width: 64, height: 64, fps: 30)
    }

    override func tearDown() async throws {
        if let videoURL {
            try? FileManager.default.removeItem(at: videoURL)
        }
        try await super.tearDown()
    }

    func testHandlerRunsOffMainThreadAndKeepsEveryThirdFrame() async throws {
        let observations = FrameObservations()
        let sampler = VideoFrameSampler()

        try await sampler.sampleFrames(from: AVURLAsset(url: videoURL)) { frame in
            // Read the thread *before* any await — an await may resume on a different thread.
            // `pthread_main_np` rather than `Thread.isMainThread`, which is marked unavailable
            // from async contexts (a Swift 6 error).
            let onMain = pthread_main_np() != 0
            await observations.record(.init(frameIndex: frame.frameIndex, onMainThread: onMain))
        }

        let entries = await observations.entries
        XCTAssertEqual(entries.map(\.frameIndex), [0, 3, 6, 9], "sampler should keep every 3rd frame")
        for entry in entries {
            XCTAssertFalse(
                entry.onMainThread,
                "frame \(entry.frameIndex): handler ran on the main thread — per-frame inference would block the UI"
            )
        }
    }

    func testTimestampsAdvanceAtSourceFrameRate() async throws {
        let sampler = VideoFrameSampler()
        let timestamps = Timestamps()

        try await sampler.sampleFrames(from: AVURLAsset(url: videoURL)) { frame in
            await timestamps.append(frame.timestamp)
        }

        let values = await timestamps.values
        XCTAssertEqual(values.count, 4)
        // Frames 0, 3, 6, 9 at 30 fps.
        for (value, expected) in zip(values, [0.0, 0.1, 0.2, 0.3]) {
            XCTAssertEqual(value, expected, accuracy: 0.001)
        }
    }

    func testAppliesPreferredTransform() async throws {
        // A 64x48 landscape-encoded video carrying the 90° preferredTransform an iPhone writes for
        // a portrait recording — [0, 1, -1, 0, tx: 48, 0], the rotation plus the translation that
        // keeps the rotated content at the origin — must decode as 48x64 with the content filling
        // the render rect.
        try await assertPreferredTransformApplies(
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0))
    }

    /// The origin-rotating sibling of `testAppliesPreferredTransform`: a bare 90° rotation with no
    /// normalizing translation puts the content outside [0, renderSize] before this PR's
    /// normalization translate, so this fixture covers the branch the iPhone-shaped fixture cannot
    /// reach. Reverting `renderTransform` to the raw `preferredTransform` leaves the render rect
    /// pure background and fails this test while the iPhone-shaped one stays green.
    func testAppliesPreferredTransformWithOriginRotation() async throws {
        try await assertPreferredTransformApplies(transform: CGAffineTransform(rotationAngle: .pi / 2))
    }

    /// Writes a 64x48 video carrying `transform` as the track's preferredTransform and asserts the
    /// sampler decodes 48x64 frames whose render rect is filled with content, not background.
    private func assertPreferredTransformApplies(transform: CGAffineTransform) async throws {
        let rotatedURL = try await Self.writeTestVideo(
            frameCount: 6, width: 64, height: 48, fps: 30, transform: transform)
        defer { try? FileManager.default.removeItem(at: rotatedURL) }

        let sampler = VideoFrameSampler()
        let rendered = RenderedFrames()
        try await sampler.sampleFrames(from: AVURLAsset(url: rotatedURL)) { frame in
            await rendered.append(RenderedFrame(
                frameIndex: frame.frameIndex,
                size: CGSize(
                    width: CVPixelBufferGetWidth(frame.pixelBuffer),
                    height: CVPixelBufferGetHeight(frame.pixelBuffer)),
                darkestChannelValue: darkestChannelValue(in: frame.pixelBuffer)))
        }

        let observed = await rendered.values
        XCTAssertFalse(observed.isEmpty, "expected the sampler to decode frames from the rotated video")
        for frame in observed {
            XCTAssertEqual(
                frame.size, CGSize(width: 48, height: 64),
                "decoded frame is \(frame.size) — the track's preferredTransform was not applied")
        }

        // Dimensions alone prove nothing: renderSize is computed from the transformed bounding box
        // whether or not the layer instruction applies the transform, so a sampler that drops the
        // rotation still emits 48x64. `writeTestVideo` fills frame N with `N * 20 % 255`, so every
        // kept frame past the first is a solid mid-gray — any part of the render rect the rotated
        // content misses stays the instruction's opaque-black background.
        let litFrames = observed.filter { $0.frameIndex > 0 }
        XCTAssertFalse(litFrames.isEmpty, "expected a kept frame past frame 0 to check rendered content")
        for frame in litFrames {
            XCTAssertGreaterThan(
                frame.darkestChannelValue, 30,
                "frame \(frame.frameIndex) has a near-black region — the rotated content did not fill the render rect")
        }
    }

    func testThrowsWhenTheAssetHasNoVideoTrack() async throws {
        let audioURL = try Self.writeAudioOnlyFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let sampler = VideoFrameSampler()

        do {
            try await sampler.sampleFrames(from: AVURLAsset(url: audioURL)) { frame in
                XCTFail("handler ran for frame \(frame.frameIndex) on an asset with no video track")
            }
            XCTFail("expected sampleFrames to throw for an asset with no video track")
        } catch let error as PoseDiagnosticError {
            guard case .videoLoadFailed = error else {
                return XCTFail("expected videoLoadFailed, got \(error)")
            }
        }
    }

    func testCompositionFrameDurationFallsBackAndThrows() throws {
        // A usable minFrameDuration wins outright.
        XCTAssertEqual(
            try VideoFrameSampler.compositionFrameDuration(
                minFrameDuration: CMTime(value: 1, timescale: 30), nominalFrameRate: 0),
            CMTime(value: 1, timescale: 30))
        // Otherwise the nominal rate sets the grid.
        XCTAssertEqual(
            try VideoFrameSampler.compositionFrameDuration(
                minFrameDuration: .invalid, nominalFrameRate: 29.97),
            CMTime(value: 1, timescale: 30))

        // Neither usable: the loud failure R1's HIGH 1 asked for. No AVAssetWriter fixture can
        // produce this pair — a writer-written track always carries a frame duration — so this
        // goes straight at the pure seam.
        do {
            _ = try VideoFrameSampler.compositionFrameDuration(
                minFrameDuration: .invalid, nominalFrameRate: 0)
            XCTFail("expected compositionFrameDuration to throw when no usable frame rate exists")
        } catch let error as PoseDiagnosticError {
            guard case .videoLoadFailed = error else {
                return XCTFail("expected videoLoadFailed, got \(error)")
            }
        } catch {
            XCTFail("expected PoseDiagnosticError.videoLoadFailed, got \(error)")
        }
    }

    // MARK: - Fixture

    /// Writes a tiny H.264 movie with `frameCount` solid-color frames so the sampler has something
    /// real to decode through AVAssetReader (bundling a fixture .mov would be larger and opaque).
    /// `transform` is written as the track's preferredTransform — e.g. a 90° rotation to mimic an
    /// iPhone portrait recording stored as landscape-encoded frames.
    private static func writeTestVideo(
        frameCount: Int, width: Int, height: Int, fps: Int32,
        transform: CGAffineTransform = .identity
    ) async throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "VideoFrameSamplerTests-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw XCTSkip("AVAssetWriter cannot add a video input on this platform")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frameCount {
            // Bounded on writer status: if the writer fails mid-write, `isReadyForMoreMediaData`
            // never becomes true, and without this check the loop would spin until XCTest's
            // timeout with no cause. Exiting instead lets `append` below surface `writer.error`.
            while !input.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
                // Vary the fill per frame so the encoder emits real (non-skipped) frames.
                memset(base, Int32(frameIndex * 20 % 255), byteCount)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? PoseDiagnosticError.videoLoadFailed(underlying: nil)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }
        return url
    }

    /// Writes a short silent CAF so the asset has an audio track and no video track.
    private static func writeAudioOnlyFile() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "VideoFrameSamplerTests-audio-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410) else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }
        buffer.frameLength = buffer.frameCapacity

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private actor Timestamps {
    private(set) var values: [TimeInterval] = []

    func append(_ value: TimeInterval) {
        values.append(value)
    }
}

private struct RenderedFrame {
    let frameIndex: Int
    let size: CGSize
    let darkestChannelValue: UInt8
}

private actor RenderedFrames {
    private(set) var values: [RenderedFrame] = []

    func append(_ value: RenderedFrame) {
        values.append(value)
    }
}

/// Smallest blue, green or red value anywhere in a BGRA frame, ignoring a 2px border where the
/// compositor blends the content's edge into the background. Alpha is skipped — the compositor
/// writes it opaque whatever the source fill was.
private func darkestChannelValue(in pixelBuffer: CVPixelBuffer) -> UInt8 {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }

    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let inset = 2
    var darkest = UInt8.max
    for y in inset..<(CVPixelBufferGetHeight(pixelBuffer) - inset) {
        for x in inset..<(CVPixelBufferGetWidth(pixelBuffer) - inset) {
            for channel in 0..<3 {
                darkest = min(darkest, bytes[y * bytesPerRow + x * 4 + channel])
            }
        }
    }
    return darkest
}
