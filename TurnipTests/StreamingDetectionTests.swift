import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import Turnip

/// The streaming detection path — `run()` over a disk-backed store, `MergedPoseFrames`,
/// the tracker over a lazy sequence — must produce the same clips as the batch path over
/// the same frames: only the frame flow differs, the signal, windows, and crop code are
/// shared. Each test compares the two routes directly, so a streamer that drops, delays,
/// or reorders a frame shows up as a different clip list.
final class StreamingDetectionTests: XCTestCase {
    private let renderSize = CGSize(width: 48, height: 64)

    /// A long take — two slides with a quiet stretch between them, one frame blanked
    /// mid-slide — through `run()` versus the batch `detectClips` over the same frames.
    /// The blanked frame exercises the single-frame-dropout bridge on both routes: a
    /// streamer that bridges wrongly splits the slide's burst and yields different clips.
    func testLongStreamingRunMatchesBatchDetection() async throws {
        let videoURL = try await TestVideoWriter.writeTestVideo(
            frameCount: 302, width: 64, height: 48, fps: 10)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let first = PoseFixture.slide(
            quietFrames: 100, from: 0.2, perFrame: 0.1, movingFrames: 6, tailFrames: 90)
        let second = PoseFixture.slide(
            quietFrames: 0, from: 0.8, perFrame: -0.1, movingFrames: 6, tailFrames: 100)
        var fixtures = (first + second).enumerated().map { index, y in
            PoseFixture.body(index: index, hip: (x: 0.5, y: y))
        }
        // Blanked mid-slide: every joint below the confidence threshold, so the two
        // samples around it are unknown and only the bridge keeps the burst whole.
        fixtures[102] = PoseFixture.body(
            index: 102, hip: (x: 0.5, y: 0.5), dropped: Set(PoseKeypoint.names))
        XCTAssertEqual(fixtures.count, 302)

        let sampler = ScriptedSampler(renderSize: renderSize, results: fixtures)
        let makeInference: ProcessingPipeline.InferenceFactory = {
            { frame in [.fixture(fixtures[frame.frameIndex].keypoints)] }
        }
        let pipeline = ProcessingPipeline(sampler: sampler, makeInference: makeInference)
        let video = SelectedVideo(
            assetIdentifier: "test", asset: AVURLAsset(url: videoURL), duration: 30.2)

        let viaRun = try await pipeline.run(video: video) { _ in }
        let duration = try await video.asset.load(.duration).seconds
        let viaDetect = pipeline.detectClips(in: fixtures, renderedPixelSize: renderSize, duration: duration)

        XCTAssertFalse(viaRun.clips.isEmpty, "the fixture should yield at least one clip to compare")
        XCTAssertEqual(viaDetect, viaRun.clips)
        XCTAssertEqual(
            viaRun.detection.poseFrames.map(\.timestamp), fixtures.map(\.timestamp),
            "every scored frame travels with the clips, in order")
    }

    /// The merged stream against the batch merge over the same live and backfilled
    /// frames: same frames kept, same frames dropped — including a backfilled frame
    /// landing within half an interval of a live sample, which both routes drop.
    func testMergedPoseFramesMatchesBatchMerge() throws {
        let yPositions = PoseFixture.slide(
            quietFrames: 15, from: 0.2, perFrame: 0.1, movingFrames: 6, tailFrames: 14)
        let fixtures = yPositions.enumerated().map { index, y in
            PoseFixture.body(index: index, hip: (x: 0.5, y: y))
        }
        let missing = Set(16...20).union(30...34)
        let live = fixtures.indices.filter { !missing.contains($0) }.map { MultiPoseFrame(single: fixtures[$0]) }
        var backfilled = missing.sorted().map { MultiPoseFrame(single: fixtures[$0]) }
        // 0.04 s from the live sample at 1.5 s — inside half the 0.1 s interval.
        backfilled.append(MultiPoseFrame(single: PoseFrameResult(
            frameIndex: 154, timestamp: 1.54, keypoints: fixtures[15].keypoints)))
        backfilled.sort { $0.timestamp < $1.timestamp }

        let liveStore = try PoseFrameStore(frames: live)
        let backfilledStore = try PoseFrameStore(frames: backfilled)
        let streamed = Array(MergedPoseFrames(
            live: liveStore, backfilled: backfilledStore, interval: 0.1, duration: 3.5))
        let batched = PoseBackfill.merged(live: live, backfilled: backfilled, interval: 0.1)

        XCTAssertEqual(streamed.map(\.frameIndex), batched.map(\.frameIndex))
        XCTAssertEqual(streamed.map(\.timestamp), batched.map(\.timestamp))

        // Frames at or past the end of the file are dropped on either side.
        let short = Array(MergedPoseFrames(
            live: liveStore, backfilled: backfilledStore, interval: 0.1, duration: 2.0))
        XCTAssertEqual(short.map(\.timestamp), batched.map(\.timestamp).filter { $0 < 2.0 })
    }

    /// The tracker over the store's lazy sequence — the shape `run()` hands it — tracks
    /// the same people as over the array: the generic walk must not depend on the frames
    /// being held.
    func testTrackerWalksTheStoresLazySequence() throws {
        let size = CGSize(width: 1000, height: 1000)
        let frames = (0..<10).map { index in
            MultiPoseFrame(
                frameIndex: index * 3, timestamp: Double(index) * PoseFixture.frameInterval,
                people: [
                    .fixture(PoseFixture.body(index: index, hip: (x: 0.2, y: 0.5)).keypoints),
                    .fixture(PoseFixture.body(index: index, hip: (x: 0.7, y: 0.5)).keypoints)
                ])
        }
        let store = try PoseFrameStore(frames: frames)

        let fromStore = PersonTracker().tracks(in: store.frames(), renderedPixelSize: size)
        let fromArray = PersonTracker().tracks(in: frames, renderedPixelSize: size)

        XCTAssertEqual(fromStore.count, fromArray.count)
        XCTAssertEqual(fromStore.map { $0.frames.map(\.timestamp) }, fromArray.map { $0.frames.map(\.timestamp) })
    }

    /// No frames, and a single frame, give no samples: there is no pair to measure.
    func testStreamerHandlesEmptyAndSingleFrameTakes() {
        let size = CGSize(width: 1000, height: 1000)
        var empty = StreamingMotionSignal(renderedPixelSize: size)
        XCTAssertTrue(empty.finish().isEmpty)
        var single = StreamingMotionSignal(renderedPixelSize: size)
        single.consume(PoseFixture.body(index: 0, hip: (x: 0.5, y: 0.5)))
        XCTAssertTrue(single.finish().isEmpty)
    }
}
