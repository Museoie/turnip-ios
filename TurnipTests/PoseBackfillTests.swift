import XCTest
@testable import Turnip

/// The grid arithmetic that decides which file times Processing samples for a take the camera
/// scored live in part, and how those samples merge back in. All at the shipped 10 samples/s.
final class PoseBackfillTests: XCTestCase {
    private let interval = 0.1

    // MARK: - Wanted times

    /// Live spacing jitters by up to a capture frame around the grid; that is not a gap.
    func testJitterAroundTheGridLeavesNothingToSample() {
        let atTwentyFourFPS = [0, 0.125, 0.2083, 0.3333, 0.4167, 0.5]
        assertTimes(PoseBackfill.wantedTimes(scored: atTwentyFourFPS, interval: interval, duration: 0.55), [])
    }

    /// Shed samples leave a hole; it is filled on the grid of the sample before it.
    func testAMidTakeGapIsFilledOnTheLiveGrid() {
        let scored = [0, 0.1, 0.2, 0.6, 0.7]
        assertTimes(PoseBackfill.wantedTimes(scored: scored, interval: interval, duration: 0.75), [0.3, 0.4, 0.5])
    }

    /// A stretch at the halved thermal rate is a gap between every pair of samples.
    func testAHalvedRateStretchIsFilledBackToTheFullRate() {
        let scored = [0, 0.2, 0.4, 0.6]
        assertTimes(PoseBackfill.wantedTimes(scored: scored, interval: interval, duration: 0.65), [0.1, 0.3, 0.5])
    }

    /// A gap that ends off the grid, as after the frame gate re-anchors, stops more than half an
    /// interval short of the sample after it.
    func testAGapStopsShortOfAnOffGridSampleAfterIt() {
        let scored = [0, 0.1, 0.35]
        assertTimes(PoseBackfill.wantedTimes(scored: scored, interval: interval, duration: 0.4), [0.2])
    }

    /// A thermal stop or a drain cut short leaves the tail; it is filled to the end of the file.
    func testTheTailIsFilledToTheEndOfTheFile() {
        let scored = [0, 0.1, 0.2]
        assertTimes(PoseBackfill.wantedTimes(scored: scored, interval: interval, duration: 0.55), [0.3, 0.4, 0.5])
    }

    func testTheHeadIsFilledBackwardFromTheFirstSample() {
        assertTimes(
            PoseBackfill.wantedTimes(scored: [0.35, 0.45], interval: interval, duration: 0.5), [0.05, 0.15, 0.25])
        assertTimes(PoseBackfill.wantedTimes(scored: [0.04, 0.14], interval: interval, duration: 0.2), [])
    }

    func testNoScoredSamplesMeansTheWholeTake() {
        assertTimes(PoseBackfill.wantedTimes(scored: [], interval: interval, duration: 0.35), [0, 0.1, 0.2, 0.3])
    }

    // MARK: - Merge

    /// A file frame lands at or after the time it was wanted for, so one can end up a few
    /// milliseconds from the live sample after its gap. Kept, it would put a few milliseconds of
    /// keypoint jitter under the motion signal's divide.
    func testABackfilledFrameCrowdingALiveSampleIsDropped() {
        let merged = PoseBackfill.merged(
            live: [frame(at: 0.7), frame(at: 0.9)],
            backfilled: [frame(at: 0.8), frame(at: 0.896)],
            interval: interval)
        assertTimes(merged.map(\.timestamp), [0.7, 0.8, 0.9])
    }

    func testMergedFramesAreInTimestampOrder() {
        let merged = PoseBackfill.merged(
            live: [frame(at: 0), frame(at: 0.4)],
            backfilled: [frame(at: 0.3), frame(at: 0.1), frame(at: 0.2)],
            interval: interval)
        assertTimes(merged.map(\.timestamp), [0, 0.1, 0.2, 0.3, 0.4])
    }

    // MARK: - Helpers

    private func frame(at timestamp: TimeInterval) -> PoseFrameResult {
        PoseFrameResult(frameIndex: 0, timestamp: timestamp, keypoints: [])
    }

    private func assertTimes(
        _ actual: [TimeInterval], _ expected: [TimeInterval], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "got \(actual)", file: file, line: line)
        for (value, want) in zip(actual, expected) {
            XCTAssertEqual(value, want, accuracy: 1e-9, "got \(actual)", file: file, line: line)
        }
    }
}
