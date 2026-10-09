import AVFoundation
import XCTest
@testable import Turnip

/// `ProcessingPipeline.run()`'s error path and the progress denominator. The happy path (the
/// crop-space test) lives in `ProcessingPipelineRunTests`.
final class ProcessingPipelineRunCoverageTests: XCTestCase {
    /// `run()` must surface a typed error for an asset with no video track, not a decoding
    /// failure from deeper in the stack. The default sampler is never reached — the guard
    /// throws before the first frame — and the default inference factory is never built, so
    /// this needs no model and no scripted sampler.
    func testRunThrowsAssetHasNoVideoTrackForAudioOnlyAsset() async throws {
        let audioURL = try TestVideoWriter.writeAudioOnlyFile()
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
        let videoURL = try await TestVideoWriter.writeTestVideo(frameCount: 30, width: 64, height: 64, fps: 30)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return XCTFail("the fixture video has no video track")
        }

        let estimated = await ProcessingPipeline.estimatedSampledFrames(of: track)
        XCTAssertEqual(estimated, 10, "30 frames at stride 3 keep 10, not 30")
    }
}
