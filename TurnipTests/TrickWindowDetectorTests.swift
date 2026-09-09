import XCTest
@testable import Turnip

final class TrickWindowDetectorTests: XCTestCase {
    private let detector = TrickWindowDetector()

    // MARK: - End-to-end over synthetic pose frames

    func testDetectsASingleSustainedPeak() {
        let frames = PoseFixture.frames(hipXPositions: Self.singlePeakPositions)

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 0.4, endsAt: 3.0)
    }

    func testMergesTwoPeaksSeparatedByLessThanTheQuietMinimum() {
        let frames = PoseFixture.frames(hipXPositions: Self.twoPeakPositions(quietFramesBetween: 5))

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 1, "two halves of one trick were reported as two tricks")
        assertWindow(windows.first, startsAt: 0.9, endsAt: 4.2)
    }

    func testSeparatesTwoPeaksWithEnoughQuietBetweenThem() {
        let frames = PoseFixture.frames(hipXPositions: Self.twoPeakPositions(quietFramesBetween: 15))

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 2)
        assertWindow(windows.first, startsAt: 0.9, endsAt: 3.3)
        assertWindow(windows.last, startsAt: 2.8, endsAt: 5.2)
    }

    /// The frame in the middle of the peak loses every keypoint to blur. Interpolating its anchor
    /// keeps the run of motion intact; without it the run splits into two halves, each too short
    /// to survive the sustained-samples minimum, and the trick disappears entirely.
    func testInterpolatesThroughADroppedConfidenceFrameRatherThanSplittingTheWindow() {
        let frames = PoseFixture.frames(hipXPositions: Self.singlePeakPositions, blankFrames: [17])

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 0.4, endsAt: 3.0)
    }

    // MARK: - Peak rules

    func testIgnoresABurstShorterThanTheSustainedMinimum() {
        let windows = detector.detectWindows(in: signal(quiet(4) + moving(2) + quiet(4)))

        XCTAssertTrue(windows.isEmpty)
    }

    func testAcceptsABurstAtExactlyTheSustainedMinimum() {
        let windows = detector.detectWindows(in: signal(quiet(4) + moving(3) + quiet(4)))

        XCTAssertEqual(windows.count, 1)
    }

    func testQuietSamplesAtTheMinimumSplitTwoPeaks() {
        let windows = detector.detectWindows(in: signal(moving(3) + quiet(12) + moving(3)))

        XCTAssertEqual(windows.count, 2)
    }

    /// A sample with no anchor is evidence of neither motion nor rest. Counting it as quiet would
    /// cut a trick in half wherever pose dropped out mid-air.
    func testUnknownSamplesDoNotSeparateTwoPeaks() {
        let windows = detector.detectWindows(in: signal(moving(3) + unknown(12) + moving(3)))

        XCTAssertEqual(windows.count, 1)
    }

    /// The two peaks sit 13 samples apart, but no single quiet stretch between them reaches the
    /// 10-sample minimum — the burst in the middle interrupts both.
    func testABurstBetweenTwoPeaksBreaksTheQuietRunThatWouldSeparateThem() {
        let windows = detector.detectWindows(
            in: signal(moving(3) + quiet(6) + moving(1) + quiet(6) + moving(3))
        )

        XCTAssertEqual(windows.count, 1)
    }

    // MARK: - Window bounds

    func testExpandsEachWindowByTheBuffer() {
        let samples = signal(quiet(20) + moving(3) + quiet(10))

        let unbuffered = TrickWindowDetector(bufferSeconds: 0).detectWindows(in: samples)
        let buffered = detector.detectWindows(in: samples)

        assertWindow(unbuffered.first, startsAt: 2.0, endsAt: 2.3)
        assertWindow(buffered.first, startsAt: 1.0, endsAt: 3.3)
    }

    func testClampsTheLeadingBufferAtTheStartOfTheVideo() {
        let windows = detector.detectWindows(in: signal(moving(3) + quiet(10)))

        assertWindow(windows.first, startsAt: 0, endsAt: 1.3)
    }

    func testAnEmptySignalProducesNoWindows() {
        XCTAssertTrue(detector.detectWindows(in: []).isEmpty)
    }

    // MARK: - Fixtures

    /// 15 still frames, a 6-frame slide at 0.1 normalized units per frame, then 14 still frames.
    private static let singlePeakPositions = PoseFixture.slide(
        quietFrames: 15, from: 0.2, perFrame: 0.1, movingFrames: 6, tailFrames: 14
    )

    private static func twoPeakPositions(quietFramesBetween: Int) -> [Float] {
        [Float](repeating: 0.1, count: 20)
            + [0.2, 0.3, 0.4, 0.5]
            + [Float](repeating: 0.5, count: quietFramesBetween)
            + [0.6, 0.7, 0.8, 0.9]
            + [Float](repeating: 0.9, count: 12)
    }

    /// Builds an already-smoothed signal directly, so a peak rule can be exercised without
    /// routing a pose fixture through the moving average first.
    private func signal(_ displacements: [Float?]) -> [MotionSample] {
        displacements.enumerated().map { index, displacement in
            MotionSample(
                startTime: Double(index) * PoseFixture.frameInterval,
                endTime: Double(index + 1) * PoseFixture.frameInterval,
                displacement: displacement
            )
        }
    }

    private func moving(_ count: Int) -> [Float?] { Array(repeating: Float(0.2), count: count) }
    private func quiet(_ count: Int) -> [Float?] { Array(repeating: Float(0), count: count) }
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
