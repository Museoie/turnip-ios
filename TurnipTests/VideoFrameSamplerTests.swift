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
        videoURL = try await Self.writeTestVideo(frameCount: 10, size: 64, fps: 30)
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

        try await sampler.sampleFrames(from: videoURL) { frame in
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

        try await sampler.sampleFrames(from: videoURL) { frame in
            await timestamps.append(frame.timestamp)
        }

        let values = await timestamps.values
        XCTAssertEqual(values.count, 4)
        // Frames 0, 3, 6, 9 at 30 fps.
        for (value, expected) in zip(values, [0.0, 0.1, 0.2, 0.3]) {
            XCTAssertEqual(value, expected, accuracy: 0.001)
        }
    }

    func testThrowsWhenTheAssetHasNoVideoTrack() async throws {
        let audioURL = try Self.writeAudioOnlyFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let sampler = VideoFrameSampler()

        do {
            try await sampler.sampleFrames(from: audioURL) { frame in
                XCTFail("handler ran for frame \(frame.frameIndex) on an asset with no video track")
            }
            XCTFail("expected sampleFrames to throw for an asset with no video track")
        } catch let error as PoseDiagnosticError {
            guard case .videoLoadFailed = error else {
                return XCTFail("expected videoLoadFailed, got \(error)")
            }
        }
    }

    // MARK: - Fixture

    /// Writes a tiny H.264 movie with `frameCount` solid-color frames so the sampler has something
    /// real to decode through AVAssetReader (bundling a fixture .mov would be larger and opaque).
    private static func writeTestVideo(frameCount: Int, size: Int, fps: Int32) async throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "VideoFrameSamplerTests-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size
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

        try await appendFrames(
            frameCount: frameCount,
            fps: fps,
            input: input,
            adaptor: adaptor,
            writer: writer
        )

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }
        return url
    }

    /// Appends `frameCount` solid-color frames to a started writer. Split out of
    /// `writeTestVideo`: the whole fixture in one function exceeds the
    /// function_body_length limit the CI lint step enforces.
    private static func appendFrames(
        frameCount: Int,
        fps: Int32,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter
    ) async throws {
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
