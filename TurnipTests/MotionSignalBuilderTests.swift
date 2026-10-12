import XCTest
@testable import Turnip

final class MotionSignalBuilderTests: XCTestCase {
    /// Square, so a normalized unit is the same number of pixels on both axes: the fixtures'
    /// default 0.1 torso is 100 px.
    private let square = CGSize(width: 1000, height: 1000)

    // MARK: - Units

    func testAStillAthleteReadsZero() throws {
        let samples = build(PoseFixture.bodies(hipXPositions: [0.5, 0.5, 0.5, 0.5]))

        XCTAssertEqual(samples.count, 3)
        for sample in samples {
            XCTAssertEqual(try XCTUnwrap(sample.speed), 0, accuracy: 0.0001)
        }
    }

    /// 10 px per 0.1 s against a 100 px torso is one torso length per second.
    func testSpeedIsInTorsoLengthsPerSecond() throws {
        let samples = build(PoseFixture.bodies(hipXPositions: (0..<6).map { 0.5 + Float($0) * 0.01 }))

        for sample in samples {
            XCTAssertEqual(try XCTUnwrap(sample.speed), 1, accuracy: 0.0001)
        }
    }

    /// The same move filmed from four times further away covers a quarter of the frame — and
    /// reads the same.
    func testTheSameMotionReadsTheSameNearAndFar() throws {
        let far = build(PoseFixture.bodies(hipXPositions: (0..<6).map { 0.5 + Float($0) * 0.025 }, torso: 0.05))
        let near = build(PoseFixture.bodies(hipXPositions: (0..<6).map { 0.2 + Float($0) * 0.1 }, torso: 0.2))

        for (farSample, nearSample) in zip(far, near) {
            XCTAssertEqual(try XCTUnwrap(farSample.speed), 5, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(nearSample.speed), 5, accuracy: 0.0001)
        }
    }

    /// In a portrait frame a normalized unit is 1920 px down but 1080 px across. Measured in
    /// frame fractions, a jump would read 1.78x slower than the same pixels of sideways travel.
    func testUpAndSidewaysReadAlikeInAPortraitFrame() throws {
        let portrait = CGSize(width: 1080, height: 1920)
        let pixelsPerFrame: Float = 54
        let sideways = (0..<6).map { index in
            PoseFixture.body(index: index, hip: (x: 0.3 + Float(index) * pixelsPerFrame / 1080, y: 0.5))
        }
        let upward = (0..<6).map { index in
            PoseFixture.body(index: index, hip: (x: 0.5, y: 0.6 - Float(index) * pixelsPerFrame / 1920))
        }

        let sidewaysSpeed = try XCTUnwrap(
            MotionSignalBuilder.buildSignal(from: sideways, renderedPixelSize: portrait)[2].speed)
        let upwardSpeed = try XCTUnwrap(
            MotionSignalBuilder.buildSignal(from: upward, renderedPixelSize: portrait)[2].speed)

        XCTAssertEqual(sidewaysSpeed, upwardSpeed, accuracy: 0.0001)
        XCTAssertGreaterThan(upwardSpeed, 0)
    }

    /// Every located joint counts, so a leg moving under still hips is motion.
    func testLimbMotionCountsWithoutHipTravel() throws {
        let frames = (0..<6).map { index in
            PoseFixture.body(
                index: index, hip: (x: 0.5, y: 0.5),
                offsets: ["right_knee": (0, -0.05 * Float(index)), "right_ankle": (0, -0.1 * Float(index))])
        }

        let speed = try XCTUnwrap(build(frames)[2].speed)

        // 50 px + 100 px of the 17 joints' travel per 0.1 s, over a 100 px torso.
        XCTAssertEqual(speed, 150 / 17 / 100 / 0.1, accuracy: 0.0001)
    }

    // MARK: - Unknown motion

    /// Two frames in a row with five joints: too few to measure, and too long a stretch to bridge.
    func testAPairWithFewerThanSixSharedJointsIsUnknown() {
        let keep: Set<String> = ["left_shoulder", "right_shoulder", "left_hip", "right_hip", "nose"]
        let frames = (0..<6).map { index in
            PoseFixture.body(
                index: index, hip: (x: 0.5, y: 0.5),
                dropped: (2...3).contains(index) ? Set(PoseKeypoint.names).subtracting(keep) : [])
        }

        let samples = build(frames)

        XCTAssertNotNil(samples[0].speed)
        XCTAssertNil(samples[1].speed, "five joints were enough to measure")
        XCTAssertNil(samples[2].speed, "five joints were enough to measure")
        XCTAssertNil(samples[3].speed, "five joints were enough to measure")
        XCTAssertNotNil(samples[4].speed)
    }

    /// Legs passing close to the lens have no torso in view, so nothing tells their size and
    /// their motion stays unknown — rather than reading as fast because they fill the frame.
    func testABodyWithNoTorsoInViewHasUnknownSpeed() {
        let frames = (0..<6).map { index in
            PoseFixture.body(
                index: index, hip: (x: 0.2 + Float(index) * 0.1, y: 0.5),
                dropped: ["left_shoulder", "right_shoulder"])
        }

        XCTAssertTrue(build(frames).allSatisfy { $0.speed == nil })
    }

    /// A torso lost for a moment — a shoulder hidden mid-turn — keeps the scale its neighbours
    /// measured, so the motion through it is still measured.
    func testTheScaleHoldsThroughABriefTorsoLoss() {
        let frames = (0..<9).map { index in
            PoseFixture.body(
                index: index, hip: (x: 0.3 + Float(index) * 0.01, y: 0.5),
                dropped: (3...5).contains(index) ? ["left_shoulder"] : [])
        }

        XCTAssertTrue(build(frames).allSatisfy { $0.speed != nil })
    }

    // MARK: - Pose-model artifacts

    /// Pose models trade left and right labels when an athlete turns side-on. A still athlete
    /// whose labels cross reads as still, not as every limb jumping across the body.
    func testCrossedLeftRightLabelsOnAStillAthleteReadAsStill() throws {
        let torso: Float = 0.1
        var crossed: [String: (x: Float, y: Float)] = [:]
        for (name, position) in PoseFixture.standingLayout {
            let mirror = name.hasPrefix("left_") ? "right_" + name.dropFirst(5)
                : name.hasPrefix("right_") ? "left_" + name.dropFirst(6) : name
            guard let other = PoseFixture.standingLayout[mirror] else { continue }
            crossed[name] = ((other.x - position.x) * torso, (other.y - position.y) * torso)
        }
        let frames = (0..<4).map { index in
            PoseFixture.body(index: index, hip: (x: 0.5, y: 0.5), torso: torso, offsets: index == 2 ? crossed : [:])
        }

        for sample in build(frames) {
            XCTAssertEqual(try XCTUnwrap(sample.speed), 0, accuracy: 0.0001)
        }
    }

    /// A one-off jump — the single-person pose landing on someone else and staying — is one raw
    /// sample. The median drops it, where a moving average would spread it over three samples —
    /// exactly enough to pass for sustained motion.
    func testAOneOffJumpIsSmoothedAway() throws {
        let positions = [Float](repeating: 0.3, count: 6) + [Float](repeating: 0.7, count: 6)

        for sample in build(PoseFixture.bodies(hipXPositions: positions)) {
            XCTAssertEqual(try XCTUnwrap(sample.speed), 0, accuracy: 0.0001)
        }
    }

    /// The median spans a fixed duration, so at 30 samples per second a 0.1 s flicker is dropped
    /// the way a single sample is at 10.
    func testTheMedianSpansAFixedDurationAtAnySampleRate() throws {
        let interval = 1.0 / 30
        let positions = [Float](repeating: 0.5, count: 10) + [0.6, 0.7, 0.8] + [Float](repeating: 0.8, count: 10)
        let frames = positions.enumerated().map { index, x in
            PoseFixture.body(index: index, hip: (x: x, y: 0.5), interval: interval)
        }

        for sample in MotionSignalBuilder.buildSignal(from: frames, renderedPixelSize: square) {
            XCTAssertEqual(try XCTUnwrap(sample.speed), 0, accuracy: 0.0001)
        }
    }

    func testSpeedDoesNotDependOnTheSampleRate() throws {
        let tenPerSecond = build(PoseFixture.bodies(hipXPositions: (0..<6).map { 0.5 + Float($0) * 0.03 }))
        let thirtyPerSecond = build(PoseFixture.bodies(
            hipXPositions: (0..<18).map { 0.5 + Float($0) * 0.01 }, interval: 1.0 / 30))

        XCTAssertEqual(try XCTUnwrap(tenPerSecond[2].speed), 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(thirtyPerSecond[8].speed), 3, accuracy: 0.0001)
    }

    /// One frame that lost every joint, mid-motion: the frames either side of it are measured
    /// against each other, and both samples touching it take that speed.
    func testASingleFrameDropoutIsBridgedFromItsNeighbours() throws {
        let frames = (0..<7).map { index in
            PoseFixture.body(
                index: index, hip: (x: 0.3 + Float(index) * 0.01, y: 0.5),
                dropped: index == 3 ? Set(PoseKeypoint.names) : [])
        }

        for sample in build(frames) {
            XCTAssertEqual(try XCTUnwrap(sample.speed), 1, accuracy: 0.0001)
        }
    }

    // MARK: - Shape of the signal

    /// Filling a gap would hand peak detection a speed for a frame pair where the athlete was
    /// never located. Two missing frames in a row are a gap, not a dropout to bridge.
    func testGapsSurviveSmoothing() {
        let frames = (0..<7).map { index in
            PoseFixture.body(
                index: index, hip: (x: 0.3 + Float(index) * 0.01, y: 0.5),
                dropped: (3...4).contains(index) ? Set(PoseKeypoint.names) : [])
        }

        let samples = build(frames)

        XCTAssertNotNil(samples[1].speed)
        XCTAssertNil(samples[2].speed)
        XCTAssertNil(samples[3].speed)
        XCTAssertNil(samples[4].speed)
        XCTAssertNotNil(samples[5].speed)
    }

    func testSampleTimesSpanTheFramePairTheyMeasure() {
        let samples = build(PoseFixture.bodies(hipXPositions: [0.1, 0.2, 0.3]))

        XCTAssertEqual(samples.count, 2, "n frames yield n-1 samples")
        XCTAssertEqual(samples[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples[0].endTime, 0.1, accuracy: 0.0001)
        XCTAssertEqual(samples[1].startTime, 0.1, accuracy: 0.0001)
        XCTAssertEqual(samples[1].endTime, 0.2, accuracy: 0.0001)
    }

    func testFewerThanTwoFramesProduceNoSamples() {
        XCTAssertTrue(build([]).isEmpty)
        XCTAssertTrue(build(PoseFixture.bodies(hipXPositions: [0.5])).isEmpty)
    }

    private func build(_ frames: [PoseFrameResult]) -> [MotionSample] {
        MotionSignalBuilder.buildSignal(from: frames, renderedPixelSize: square)
    }
}
