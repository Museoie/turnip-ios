import AVFoundation
import CoreVideo
import XCTest
@testable import Turnip

/// The rest of issue #98's coverage: `ProcessingPipeline.run()`'s error path and the progress
/// denominator.
///
/// Part 1's happy path (the crop-space regression test) and the `TestVideoWriter` hoist live in
/// open PR #110, which also owns `ProcessingPipelineRunTests` — this class takes the remaining
/// seams so the two PRs merge without touching the same symbols.
final class ProcessingPipelineRunCoverageTests: XCTestCase {
    /// `run()` must surface a typed error for an asset with no video track, not a decoding
    /// failure from deeper in the stack. The default sampler is never reached — the guard
    /// throws before the first frame — and the default inference factory is never built, so
    /// this needs no model and no scripted sampler.
    func testRunThrowsAssetHasNoVideoTrackForAudioOnlyAsset() async throws {
        let audioURL = try writeAudioOnlyFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let pipeline = ProcessingPipeline()
        let video = SelectedVideo(
            assetIdentifier: "test",
            asset: AVURLAsset(url: audioURL),
            duration: 1
        )

        do {
            _ = try await pipeline.run(video: video) { _ in }
            XCTFail("expected run to throw for an asset with no video track")
        } catch let error as ProcessingError {
            guard case .assetHasNoVideoTrack = error else {
                return XCTFail("expected assetHasNoVideoTrack, got \(error)")
            }
        }
    }

    /// The progress denominator is an estimate, not a count of decoded frames: 30 frames at
    /// 30 fps with the pipeline's stride of 3 keeps frames 0, 3, …, 27 — ten, not thirty.
    /// This pins `estimatedSampledFrames` against a real track; the pure `sampledFrameCount`
    /// rounding already has its own tests.
    func testEstimatedSampledFramesMatchesTheSamplerKeptCount() async throws {
        let videoURL = try await writeCountableVideo(frameCount: 30, fps: 30)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return XCTFail("the fixture video has no video track")
        }

        let estimated = await ProcessingPipeline.estimatedSampledFrames(of: track)
        XCTAssertEqual(estimated, 10, "30 frames at stride 3 keep 10, not 30")
    }
}

// MARK: - Fixtures

/// A short silent CAF: the asset has an audio track and no video track. Local copy of the
/// `VideoFrameSamplerTests` fixture — that helper is private until the shared `TestVideoWriter`
/// lands with #110.
private func writeAudioOnlyFile() throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "ProcessingRunCoverageTests-audio-\(UUID().uuidString).caf")

    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410) else {
        throw PoseError.videoLoadFailed(underlying: nil)
    }
    buffer.frameLength = buffer.frameCapacity

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

/// Writes a tiny H.264 movie with `frameCount` blank frames at `fps`, so `estimatedSampledFrames`
/// has a real track to read its duration and frame rate from. Frame *content* is irrelevant here —
/// nothing decodes it — so unlike the sampler fixtures this skips the per-frame fill. Local until
/// the shared `TestVideoWriter` lands with #110, which owns the canonical fixture writer.
private func writeCountableVideo(frameCount: Int, fps: Int32) async throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "ProcessingRunCoverageTests-\(UUID().uuidString).mov")

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 64
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ]
    )
    guard writer.canAdd(input) else {
        throw XCTSkip("AVAssetWriter cannot add a video input on this platform")
    }
    writer.add(input)

    guard writer.startWriting() else {
        throw writer.error ?? PoseError.videoLoadFailed(underlying: nil)
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
            throw PoseError.videoLoadFailed(underlying: nil)
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw PoseError.videoLoadFailed(underlying: nil)
        }
        let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw writer.error ?? PoseError.videoLoadFailed(underlying: nil)
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw writer.error ?? PoseError.videoLoadFailed(underlying: nil)
    }
    return url
}
