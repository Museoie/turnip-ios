import XCTest
@testable import Turnip

final class TrickWindowDetectorTests: XCTestCase {
    private let detector = TrickWindowDetector()

    // MARK: - End-to-end over synthetic pose frames

    /// 15 still frames, a 6-frame slide at 2 torso lengths per frame (20 torso lengths/s), then
    /// 14 still frames.
    func testDetectsASingleSustainedSlide() {
        let frames = PoseFixture.bodies(hipXPositions: Self.singleSlidePositions)

        let windows = detector.detectWindows(in: signal(of: frames))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 0.4, endsAt: 5.0)
    }

    /// A kick moves a leg, not the hips: the athlete's hip midpoint never moves here, and the
    /// kick must still read as a trick.
    func testDetectsAKickThatNeverMovesTheHips() {
        let frames = (0..<40).map { index -> PoseFrameResult in
            let kicking = (15..<21).contains(index)
            let lift: Float = kicking ? (index.isMultiple(of: 2) ? -0.25 : 0) : 0
            return PoseFixture.body(
                index: index, hip: (x: 0.5, y: 0.5),
                offsets: ["right_knee": (0.1 * lift, lift), "right_ankle": (0.2 * lift, 2 * lift),
                          "left_wrist": (0, lift), "right_wrist": (0, lift)])
        }

        let windows = detector.detectWindows(in: signal(of: frames))

        XCTAssertEqual(windows.count, 1, "a kick with still hips was not detected")
    }

    /// One frame where the pose lands somewhere else entirely — the model's single-person output
    /// jumping to a bystander and back. The two spikes it makes last 0.2 s, under the sustained
    /// minimum, as long as smoothing does not spread them across their neighbours.
    func testIgnoresASingleGlitchedFrame() {
        var positions = [Float](repeating: 0.5, count: 30)
        positions[15] = 0.8

        let windows = detector.detectWindows(in: signal(of: PoseFixture.bodies(hipXPositions: positions)))

        XCTAssertTrue(windows.isEmpty, "a one-frame glitch passed for a trick")
    }

    /// The same failure as a one-way jump: the pose switches to another person and stays.
    func testIgnoresAOneOffJumpInPosition() {
        let positions = [Float](repeating: 0.3, count: 15) + [Float](repeating: 0.7, count: 15)

        let windows = detector.detectWindows(in: signal(of: PoseFixture.bodies(hipXPositions: positions)))

        XCTAssertTrue(windows.isEmpty, "a one-off jump passed for a trick")
    }

    /// The frame in the middle of the slide loses every keypoint to blur. Without bridging it, the
    /// two unknown samples around it end the burst, both halves fall under the sustained minimum,
    /// and the trick disappears.
    func testADroppedFrameMidTrickDoesNotSplitIt() {
        var frames = PoseFixture.bodies(hipXPositions: Self.singleSlidePositions)
        frames[17] = PoseFixture.body(
            index: 17, hip: (x: Self.singleSlidePositions[17], y: 0.5), dropped: Set(PoseKeypoint.names))

        let windows = detector.detectWindows(in: signal(of: frames))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 0.4, endsAt: 5.0)
    }

    /// Someone walking past close to the lens crosses 6% of the frame per sample — more than the
    /// far athlete's flips cover — but in torso lengths it is a walk, 1.5 per second.
    func testAPasserByAtTheLensIsNotATrick() {
        let positions = (0..<30).map { 0.2 + Float($0) * 0.06 }

        let windows = detector.detectWindows(
            in: signal(of: PoseFixture.bodies(hipXPositions: positions, torso: 0.4)))

        XCTAssertTrue(windows.isEmpty, "a close walker was read as a trick")
    }

    // MARK: - Burst rules

    func testIgnoresABurstShorterThanTheSustainedMinimum() {
        XCTAssertTrue(detector.detectWindows(in: speeds(still(30) + fast(2) + still(30))).isEmpty)
    }

    func testAcceptsABurstAtExactlyTheSustainedMinimum() {
        XCTAssertEqual(detector.detectWindows(in: speeds(still(30) + fast(3) + still(30))).count, 1)
    }

    func testQuietAtTheMinimumSplitsTwoBursts() {
        let windows = detector.detectWindows(in: speeds(still(30) + fast(3) + still(10) + fast(3) + still(30)))

        XCTAssertEqual(windows.count, 2)
    }

    func testQuietShorterThanTheMinimumMergesTwoBursts() {
        let windows = detector.detectWindows(in: speeds(still(30) + fast(3) + still(9) + fast(3) + still(30)))

        XCTAssertEqual(windows.count, 1)
    }

    /// A sample with no speed is evidence of neither motion nor rest. Counting it as quiet would
    /// cut a trick in half wherever pose dropped out mid-air.
    func testUnknownSamplesDoNotSeparateTwoBursts() {
        let windows = detector.detectWindows(in: speeds(still(30) + fast(3) + unknown(12) + fast(3) + still(30)))

        XCTAssertEqual(windows.count, 1)
    }

    /// One frame pair of lost pose inside a burst is bridged. Closing the burst there would leave
    /// two halves each under the sustained minimum, and the trick would disappear.
    func testASingleUnknownSampleDoesNotEndABurst() {
        let windows = detector.detectWindows(in: speeds(still(30) + fast(2) + unknown(1) + fast(2) + still(30)))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 2.0, endsAt: 3.5 + 3)
    }

    func testTwoConsecutiveUnknownSamplesEndABurst() {
        let windows = detector.detectWindows(in: speeds(still(30) + fast(2) + unknown(2) + fast(2) + still(30)))

        XCTAssertTrue(windows.isEmpty)
    }

    /// The two bursts sit 1.3 s apart, but no single quiet stretch between them reaches 1 s —
    /// the blip in the middle interrupts both.
    func testMotionBetweenTwoBurstsBreaksTheQuietThatWouldSeparateThem() {
        let windows = detector.detectWindows(
            in: speeds(still(30) + fast(3) + still(6) + fast(1) + still(6) + fast(3) + still(30)))

        XCTAssertEqual(windows.count, 1)
    }

    // MARK: - Measured against the athlete's own activity

    /// Bouncing on a sprung floor is steady motion well above the speed floor. A burst only a
    /// little faster than it is more of the same, not a trick.
    func testABurstThatDoesNotStandOutFromSteadyActivityIsIgnored() {
        let windows = detector.detectWindows(in: speeds(steady(4, 50) + steady(6, 5) + steady(4, 50)))

        XCTAssertTrue(windows.isEmpty)
    }

    func testABurstThatStandsOutFromSteadyActivityIsDetected() {
        let windows = detector.detectWindows(in: speeds(steady(4, 50) + steady(10, 5) + steady(4, 50)))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 4.0, endsAt: 5.5 + 3)
    }

    /// Below the floor nothing counts, however still the athlete was before: a still athlete's
    /// keypoint jitter over a near-zero median would otherwise read as a burst.
    func testSpeedsAtOrBelowTheFloorNeverCount() {
        let floor = detector.minimumSpeed

        XCTAssertTrue(detector.detectWindows(in: speeds(still(30) + steady(floor, 5) + still(30))).isEmpty)
        XCTAssertEqual(detector.detectWindows(in: speeds(still(30) + steady(floor + 0.5, 5) + still(30))).count, 1)
    }

    /// Mid-trick moments that read slower than the peak (the top of a flip, a plant between two
    /// kicks) stay inside the burst while they hold above the exit ratio.
    func testABurstHoldsThroughASlowerMomentAboveTheExitRatio() {
        // Over a steady 4, a 7 is 1.75x: under the 2x entry ratio, over the 1.4x exit ratio.
        let burst = steady(10, 2) + steady(7, 2) + steady(10, 2)

        let windows = detector.detectWindows(in: speeds(steady(4, 50) + burst + steady(4, 50)))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 4.0, endsAt: 5.6 + 3)
    }

    /// A known limitation, pinned so that changing it is a decision: a burst holding one speed for
    /// longer than about `baselineHalfWindow` fills most of its own baseline window and stops
    /// standing out from it. Four seconds still reads as a trick; six seconds reads as the
    /// athlete's normal activity. Capping the baseline at an activity level would keep long bursts,
    /// but no labelled footage yet has a burst that long to choose the cap from.
    func testAUniformBurstLongerThanTheBaselineHalfWindowIsLost() {
        XCTAssertEqual(detector.detectWindows(in: speeds(still(60) + fast(40) + still(60))).count, 1)
        XCTAssertTrue(detector.detectWindows(in: speeds(still(60) + fast(60) + still(60))).isEmpty)
    }

    // MARK: - Sample rate

    /// Every threshold is a duration, so the same signal sampled three times as densely detects
    /// the same window.
    func testDurationsDoNotDependOnTheSampleRate() {
        let tenPerSecond = detector.detectWindows(in: speeds(still(30) + fast(5) + still(30)))
        let thirtyPerSecond = detector.detectWindows(
            in: speeds(still(90) + fast(15) + still(90), interval: 1.0 / 30))

        XCTAssertEqual(tenPerSecond.count, 1)
        XCTAssertEqual(thirtyPerSecond.count, 1)
        assertWindow(thirtyPerSecond.first, startsAt: tenPerSecond[0].startTime, endsAt: tenPerSecond[0].endTime)
    }

    /// 0.2 s of motion is under the 0.3 s minimum at any rate — six samples at 30 per second
    /// are not "sustained" just because six is more than three.
    func testTheSustainedMinimumIsADurationNotASampleCount() {
        let windows = detector.detectWindows(in: speeds(still(90) + fast(6) + still(90), interval: 1.0 / 30))

        XCTAssertTrue(windows.isEmpty)
    }

    // MARK: - Window bounds

    func testExpandsEachWindowByItsOwnLeadingAndTrailingBuffer() {
        let samples = speeds(still(30) + fast(3) + still(30))

        let unbuffered = TrickWindowDetector(leadingBufferSeconds: 0, trailingBufferSeconds: 0)
            .detectWindows(in: samples)
        let buffered = detector.detectWindows(in: samples)

        assertWindow(unbuffered.first, startsAt: 3.0, endsAt: 3.3)
        // The trailing buffer is larger, so a detected trick keeps playing well past the moment
        // its motion goes quiet instead of cutting at the landing.
        assertWindow(buffered.first, startsAt: 2.0, endsAt: 6.3)
    }

    func testClampsTheLeadingBufferAtTheStartOfTheVideo() {
        let windows = detector.detectWindows(in: speeds(fast(3) + still(30)))

        assertWindow(windows.first, startsAt: 0, endsAt: 3.3)
    }

    func testAnEmptySignalProducesNoWindows() {
        XCTAssertTrue(detector.detectWindows(in: []).isEmpty)
    }

    // MARK: - Fixtures

    private static let singleSlidePositions = PoseFixture.slide(
        quietFrames: 15, from: 0.2, perFrame: 0.2, movingFrames: 6, tailFrames: 14)

    private func signal(of frames: [PoseFrameResult]) -> [MotionSample] {
        MotionSignalBuilder.buildSignal(from: frames, renderedPixelSize: CGSize(width: 1000, height: 1000))
    }

    /// A signal built directly from speeds, so a burst rule can be exercised without routing pose
    /// fixtures through the signal builder.
    private func speeds(_ values: [Float?], interval: TimeInterval = PoseFixture.frameInterval) -> [MotionSample] {
        values.enumerated().map { index, speed in
            MotionSample(startTime: Double(index) * interval, endTime: Double(index + 1) * interval, speed: speed)
        }
    }

    private func still(_ count: Int) -> [Float?] { Array(repeating: 0, count: count) }
    private func fast(_ count: Int) -> [Float?] { Array(repeating: 8, count: count) }
    private func steady(_ speed: Float, _ count: Int) -> [Float?] { Array(repeating: speed, count: count) }
    private func unknown(_ count: Int) -> [Float?] { Array(repeating: nil, count: count) }

    private func assertWindow(
        _ window: TrickWindow?,
        startsAt start: TimeInterval,
        endsAt end: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let window else {
            return XCTFail("expected a window", file: file, line: line)
        }
        XCTAssertEqual(window.startTime, start, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(window.endTime, end, accuracy: 0.0001, file: file, line: line)
    }
}
