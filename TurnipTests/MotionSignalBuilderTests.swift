import XCTest
@testable import Turnip

final class MotionSignalBuilderTests: XCTestCase {

    // MARK: - Anchor resolution

    func testHipAnchorIsTheMidpointOfBothHips() throws {
        let frame = PoseFixture.frame(
            index: 0,
            hip: nil,
            leftHip: (x: 0.4, y: 0.5, confidence: 0.9),
            rightHip: (x: 0.6, y: 0.7, confidence: 0.9)
        )

        let anchor = try XCTUnwrap(MotionSignalBuilder.anchors(for: [frame])[0])

        XCTAssertEqual(anchor.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, 0.6, accuracy: 0.0001)
        XCTAssertEqual(anchor.source, .hips)
    }

    func testHipAnchorAveragesOnlyTheHipsAboveTheConfidenceThreshold() throws {
        let frame = PoseFixture.frame(
            index: 0,
            hip: nil,
            leftHip: (x: 0.4, y: 0.5, confidence: 0.9),
            rightHip: (x: 0.9, y: 0.9, confidence: 0.1)
        )

        let anchor = try XCTUnwrap(MotionSignalBuilder.anchors(for: [frame])[0])

        XCTAssertEqual(anchor.x, 0.4, accuracy: 0.0001, "the low-confidence hip was averaged in")
        XCTAssertEqual(anchor.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(anchor.source, .hips)
    }

    func testFallsBackToTheUpperBodyAnchorWhenBothHipsFail() throws {
        let frame = PoseFixture.frame(index: 0, hip: nil, upperBody: (x: 0.3, y: 0.2))

        let anchor = try XCTUnwrap(MotionSignalBuilder.anchors(for: [frame])[0])

        XCTAssertEqual(anchor.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, 0.2, accuracy: 0.0001)
        XCTAssertEqual(anchor.source, .upperBody)
    }

    func testProducesNoAnchorWhenEveryCandidateKeypointFails() {
        let frame = PoseFixture.frame(index: 0, hip: nil)

        XCTAssertNil(MotionSignalBuilder.anchors(for: [frame])[0])
    }

    // MARK: - Gap interpolation

    func testInterpolatesASingleFrameAnchorGapFromItsNeighbours() throws {
        let frames = PoseFixture.frames(hipXPositions: [0.2, 0.4, 0.0, 0.8], blankFrames: [2])

        let anchor = try XCTUnwrap(MotionSignalBuilder.anchors(for: frames)[2])

        XCTAssertEqual(anchor.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(anchor.source, .hips)
    }

    /// Interpolation reads its neighbours from the unfilled input, so a two-frame hole cannot
    /// close by having the first estimate feed the second.
    func testDoesNotInterpolateTwoConsecutiveAnchorGaps() {
        let frames = PoseFixture.frames(hipXPositions: [0.2, 0.4, 0.0, 0.0, 0.8], blankFrames: [2, 3])

        let anchors = MotionSignalBuilder.anchors(for: frames)

        XCTAssertNil(anchors[2])
        XCTAssertNil(anchors[3])
    }

    // MARK: - Displacement

    /// A hip midpoint and an upper-body midpoint sit a torso apart. Differencing across the two
    /// would report that offset as a burst of athlete motion several times the peak threshold.
    func testDisplacementIsUnknownAcrossAnAnchorSourceChange() throws {
        let frames = [
            PoseFixture.frame(index: 0, hip: (x: 0.5, y: 0.5)),
            PoseFixture.frame(index: 1, hip: (x: 0.5, y: 0.5)),
            PoseFixture.frame(index: 2, hip: nil, upperBody: (x: 0.5, y: 0.2)),
            PoseFixture.frame(index: 3, hip: nil, upperBody: (x: 0.5, y: 0.2))
        ]

        let samples = MotionSignalBuilder.buildSignal(from: frames)

        XCTAssertEqual(try XCTUnwrap(samples[0].displacement), 0, accuracy: 0.0001)
        XCTAssertNil(samples[1].displacement, "the torso offset was measured as motion")
        XCTAssertEqual(try XCTUnwrap(samples[2].displacement), 0, accuracy: 0.0001)
    }

    func testSampleTimesSpanTheFramePairTheyMeasure() {
        let frames = PoseFixture.frames(hipXPositions: [0.1, 0.2, 0.3])

        let samples = MotionSignalBuilder.buildSignal(from: frames)

        XCTAssertEqual(samples.count, 2, "n frames yield n-1 displacements")
        XCTAssertEqual(samples[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples[0].endTime, 0.1, accuracy: 0.0001)
        XCTAssertEqual(samples[1].startTime, 0.1, accuracy: 0.0001)
        XCTAssertEqual(samples[1].endTime, 0.2, accuracy: 0.0001)
    }

    func testFewerThanTwoFramesProduceNoSamples() {
        XCTAssertTrue(MotionSignalBuilder.buildSignal(from: []).isEmpty)
        XCTAssertTrue(MotionSignalBuilder.buildSignal(from: PoseFixture.frames(hipXPositions: [0.5])).isEmpty)
    }

    // MARK: - Smoothing

    func testSmoothsWithAThreeSampleMovingAverage() throws {
        let frames = PoseFixture.frames(hipXPositions: [0.0, 0.0, 0.3, 0.3, 0.3])

        let smoothed = MotionSignalBuilder.buildSignal(from: frames)

        // Raw displacements are [0, 0.3, 0, 0]; the window is clipped at both ends.
        XCTAssertEqual(try XCTUnwrap(smoothed[0].displacement), 0.15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(smoothed[1].displacement), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(smoothed[2].displacement), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(smoothed[3].displacement), 0.0, accuracy: 0.0001)
    }

    /// Averaging a gap away would hand peak detection a displacement for a frame pair where the
    /// athlete was never located.
    func testGapsSurviveSmoothing() {
        let frames = PoseFixture.frames(
            hipXPositions: [0.1, 0.2, 0.0, 0.0, 0.5, 0.6],
            blankFrames: [2, 3]
        )

        let samples = MotionSignalBuilder.buildSignal(from: frames)

        XCTAssertNotNil(samples[0].displacement)
        XCTAssertNil(samples[1].displacement)
        XCTAssertNil(samples[2].displacement)
        XCTAssertNil(samples[3].displacement)
        XCTAssertNotNil(samples[4].displacement)
    }
}
