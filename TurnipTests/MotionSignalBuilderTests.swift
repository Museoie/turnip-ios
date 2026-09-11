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

    // MARK: - Partial-group anchors

    /// A one-hip frame between two full-hip frames must not read as motion: the anchor is the
    /// full-group midpoint reconstructed from the neighbouring frame's hip geometry, so a
    /// stationary athlete measures zero displacement on both sides.
    /// Negative control: without reconstruction the middle frame anchors on the lone hip and
    /// both samples read 0.06 — above the 0.05 displacement threshold even after smoothing.
    func testOneHipDropoutOnAStationaryAthleteStaysQuiet() throws {
        let frames = [
            PoseFixture.frame(
                index: 0,
                hip: nil,
                leftHip: (x: 0.44, y: 0.55, confidence: 0.9),
                rightHip: (x: 0.56, y: 0.55, confidence: 0.9)
            ),
            PoseFixture.frame(
                index: 1,
                hip: nil,
                leftHip: (x: 0.44, y: 0.55, confidence: 0.9),
                rightHip: (x: 0.56, y: 0.55, confidence: 0.1)
            ),
            PoseFixture.frame(
                index: 2,
                hip: nil,
                leftHip: (x: 0.44, y: 0.55, confidence: 0.9),
                rightHip: (x: 0.56, y: 0.55, confidence: 0.9)
            )
        ]

        let anchors = MotionSignalBuilder.anchors(for: frames)
        let samples = MotionSignalBuilder.buildSignal(from: frames)

        // The reconstructed anchor estimates the full-group midpoint, so it carries the full
        // group's identity and compares against its genuine full-group neighbours.
        XCTAssertEqual(try XCTUnwrap(anchors[1]).members, MotionSignalBuilder.hipKeypointNames)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(try XCTUnwrap(samples[0].displacement), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(samples[1].displacement), 0, accuracy: 0.0001)
    }

    /// The same defect one level down: the upper-body group's three members are not symmetric
    /// about a common center, so a nose-only frame after an all-three frame reads 0.053 of
    /// motion without reconstruction.
    /// Negative control: without reconstruction both samples read 0.053 — above threshold.
    func testNoseOnlyDropoutOnAStationaryAthleteStaysQuiet() throws {
        let frames = [
            upperBodyFrame(index: 0, seeds: [
                "left_shoulder": (x: 0.42, y: 0.30, confidence: 0.9),
                "right_shoulder": (x: 0.58, y: 0.30, confidence: 0.9),
                "nose": (x: 0.50, y: 0.22, confidence: 0.9)
            ]),
            upperBodyFrame(index: 1, seeds: [
                "nose": (x: 0.50, y: 0.22, confidence: 0.9)
            ]),
            upperBodyFrame(index: 2, seeds: [
                "left_shoulder": (x: 0.42, y: 0.30, confidence: 0.9),
                "right_shoulder": (x: 0.58, y: 0.30, confidence: 0.9),
                "nose": (x: 0.50, y: 0.22, confidence: 0.9)
            ])
        ]

        let samples = MotionSignalBuilder.buildSignal(from: frames)

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(try XCTUnwrap(samples[0].displacement), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(samples[1].displacement), 0, accuracy: 0.0001)
    }

    /// With no recent full-group frame to reconstruct from, a partial anchor keeps its partial
    /// identity and its displacement stays unknown — rather than measuring the subset offset
    /// as motion.
    func testPartialAnchorWithoutARecentFullGroupFrameHasUnknownDisplacement() {
        let frames = [
            PoseFixture.frame(
                index: 0,
                hip: nil,
                leftHip: (x: 0.44, y: 0.55, confidence: 0.9),
                rightHip: (x: 0.56, y: 0.55, confidence: 0.1)
            ),
            PoseFixture.frame(
                index: 1,
                hip: nil,
                leftHip: (x: 0.44, y: 0.55, confidence: 0.9),
                rightHip: (x: 0.56, y: 0.55, confidence: 0.9)
            )
        ]

        let samples = MotionSignalBuilder.buildSignal(from: frames)

        XCTAssertEqual(samples.count, 1)
        XCTAssertNil(samples[0].displacement, "the subset offset was measured as motion")
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

    // MARK: - Helpers

    /// A frame whose upper-body keypoints carry individual positions and confidences; every
    /// other keypoint sits below the confidence threshold. The shared fixture writes one
    /// position into the whole group, which cannot express a nose-only dropout.
    private func upperBodyFrame(
        index: Int,
        seeds: [String: (x: Float, y: Float, confidence: Float)]
    ) -> PoseFrameResult {
        let keypoints = PoseKeypoint.names.map { name -> PoseKeypoint in
            if let seed = seeds[name] {
                return PoseKeypoint(name: name, y: seed.y, x: seed.x, confidence: seed.confidence)
            }
            return PoseKeypoint(name: name, y: 0, x: 0, confidence: 0.05)
        }
        return PoseFrameResult(
            frameIndex: index * 3,
            timestamp: Double(index) * PoseFixture.frameInterval,
            keypoints: keypoints
        )
    }
}
