import AVFoundation
import XCTest
@testable import Turnip

/// The live pose path's pure pieces (docs/LIVE_POSE.md "Tradeoffs recorded"): the frame gate, the
/// queue bound and drop policy, the timestamp offset, the thermal policy, the keypoint rotation
/// and the channel hand-off. The capture side itself needs a device.
final class LivePoseTests: XCTestCase {
    // MARK: - Bounded queue

    func testQueueIsFIFOAndDropsOldestOnOverflow() {
        var queue = BoundedSampleQueue<Int>(capacity: 3)

        XCTAssertNil(queue.push(1))
        XCTAssertNil(queue.push(2))
        XCTAssertNil(queue.push(3))
        XCTAssertEqual(queue.push(4), 1, "the oldest element is the one shed")
        XCTAssertEqual(queue.push(5), 2)

        XCTAssertEqual(queue.dropCount, 2)
        XCTAssertEqual(queue.pushCount, 5)
        XCTAssertEqual(queue.pop(), 3)
        XCTAssertEqual(queue.pop(), 4)
        XCTAssertEqual(queue.pop(), 5)
        XCTAssertNil(queue.pop())
    }

    func testQueueTracksItsHighWaterMark() {
        var queue = BoundedSampleQueue<Int>(capacity: 10)

        queue.push(1)
        queue.push(2)
        queue.push(3)
        _ = queue.pop()
        _ = queue.pop()
        queue.push(4)

        XCTAssertEqual(queue.maxDepth, 3, "max depth is the deepest the queue ever got, not its current size")
        XCTAssertEqual(queue.dropCount, 0)
    }

    // MARK: - Thermal policy

    func testThermalPolicyHalvesAtSeriousAndStopsAtCritical() {
        XCTAssertEqual(LivePoseThermalPolicy.response(to: .nominal), .normal)
        XCTAssertEqual(LivePoseThermalPolicy.response(to: .fair), .normal)
        XCTAssertEqual(LivePoseThermalPolicy.response(to: .serious), .halved)
        XCTAssertEqual(LivePoseThermalPolicy.response(to: .critical), .stopped)

        XCTAssertEqual(LivePoseThermalPolicy.sampleInterval(base: 0.1, response: .normal), 0.1)
        XCTAssertEqual(LivePoseThermalPolicy.sampleInterval(base: 0.1, response: .halved), 0.2)
        XCTAssertNil(LivePoseThermalPolicy.sampleInterval(base: 0.1, response: .stopped))
    }

    // MARK: - Frame gate

    /// The default interval is the file sampler's rate, so the two paths sample alike.
    func testGateDefaultsToTheFileSamplerRate() {
        XCTAssertEqual(LivePoseFrameGate.defaultInterval, 1.0 / Double(VideoFrameSampler.targetSamplesPerSecond))
    }

    /// 240 fps frames, 4.1667 ms apart: the gate keeps one per 100 ms and is insensitive to the
    /// per-frame jitter that a frame-counting stride would compound.
    func testGateKeepsTenPerSecondAt240fps() {
        var gate = LivePoseFrameGate()
        let frameDuration = 1.0 / 240
        var kept: [Int] = []
        for frame in 0..<480 where gate.admits(presentationTime: Double(frame) * frameDuration) {
            kept.append(frame)
        }

        XCTAssertEqual(kept.count, 20, "two seconds at 10 samples/sec")
        XCTAssertEqual(kept.first, 0)
        // Every kept frame is 24 frames after the last, the stride the file path uses at 240 fps.
        for (earlier, later) in zip(kept, kept.dropFirst()) {
            XCTAssertEqual(later - earlier, 24, "kept frames \(earlier) and \(later) are not one slot apart")
        }
    }

    /// Skipped frames do not shift the grid: when the capture output discards the frames after a
    /// kept one, the next kept frame is still the one at the next slot.
    func testGateStaysOnItsGridWhenFramesAreSkipped() {
        var gate = LivePoseFrameGate(baseInterval: 0.1)

        XCTAssertTrue(gate.admits(presentationTime: 0))
        // The frames at 0.004..0.03 were discarded while frame 0 was being preprocessed.
        XCTAssertFalse(gate.admits(presentationTime: 0.033))
        XCTAssertFalse(gate.admits(presentationTime: 0.096))
        XCTAssertTrue(gate.admits(presentationTime: 0.104))
        // Still anchored at 0: the next slot is 0.2, not 0.204.
        XCTAssertFalse(gate.admits(presentationTime: 0.196))
        XCTAssertTrue(gate.admits(presentationTime: 0.2))
    }

    /// A gap longer than one interval re-anchors instead of admitting a burst to catch up.
    func testGateReanchorsAfterAGapInsteadOfBursting() {
        var gate = LivePoseFrameGate(baseInterval: 0.1)

        XCTAssertTrue(gate.admits(presentationTime: 0))
        XCTAssertTrue(gate.admits(presentationTime: 1.0))
        XCTAssertFalse(gate.admits(presentationTime: 1.004), "a burst of catch-up samples is what a queue drains into")
        XCTAssertFalse(gate.admits(presentationTime: 1.096))
        XCTAssertTrue(gate.admits(presentationTime: 1.1))
    }

    func testGateDoublesItsIntervalUnderSeriousAndStopsUnderCritical() {
        var gate = LivePoseFrameGate(baseInterval: 0.1)

        XCTAssertTrue(gate.admits(presentationTime: 0))
        gate.thermal = .halved
        XCTAssertFalse(gate.admits(presentationTime: 0.1))
        XCTAssertTrue(gate.admits(presentationTime: 0.2))
        gate.thermal = .stopped
        XCTAssertNil(gate.currentInterval)
        for time in stride(from: 0.3, through: 2.0, by: 0.1) {
            XCTAssertFalse(gate.admits(presentationTime: time), "t=\(time): nothing is kept under critical")
        }
        gate.thermal = .normal
        XCTAssertTrue(gate.admits(presentationTime: 2.1), "sampling resumes when the state cools")
    }

    // MARK: - Timestamp anchor

    func testAnchorRebasesOntoTheFirstTimestampItSees() {
        var anchor = LivePoseTimestampAnchor()

        XCTAssertNil(anchor.anchor)
        XCTAssertEqual(anchor.fileRelative(1234.5), 0)
        XCTAssertEqual(anchor.anchor, 1234.5)
        XCTAssertEqual(anchor.fileRelative(1234.6), 0.1, accuracy: 1e-9)
        XCTAssertEqual(anchor.fileRelative(1237.5), 3.0, accuracy: 1e-9)
    }

    // MARK: - Keypoint rotation

    func testRelativeDegreesWrapsAround() {
        XCTAssertEqual(LivePoseKeypointRotation.relativeDegrees(producer: 0, consumer: 90), 90)
        XCTAssertEqual(LivePoseKeypointRotation.relativeDegrees(producer: 90, consumer: 0), 270)
        XCTAssertEqual(LivePoseKeypointRotation.relativeDegrees(producer: 180, consumer: 180), 0)
        XCTAssertEqual(LivePoseKeypointRotation.relativeDegrees(producer: 270, consumer: 90), 180)
    }

    /// A joint near the top-left of a landscape sensor frame lands near the top-right after the
    /// quarter-turn clockwise that makes the frame portrait; the other turns follow.
    func testRotatedPointFollowsAClockwiseQuarterTurn() {
        let (x90, y90) = LivePoseKeypointRotation.rotatedPoint(x: 0.1, y: 0.2, clockwiseDegrees: 90)
        XCTAssertEqual(x90, 0.8, accuracy: 1e-6)
        XCTAssertEqual(y90, 0.1, accuracy: 1e-6)

        let (x180, y180) = LivePoseKeypointRotation.rotatedPoint(x: 0.1, y: 0.2, clockwiseDegrees: 180)
        XCTAssertEqual(x180, 0.9, accuracy: 1e-6)
        XCTAssertEqual(y180, 0.8, accuracy: 1e-6)

        let (x270, y270) = LivePoseKeypointRotation.rotatedPoint(x: 0.1, y: 0.2, clockwiseDegrees: 270)
        XCTAssertEqual(x270, 0.2, accuracy: 1e-6)
        XCTAssertEqual(y270, 0.9, accuracy: 1e-6)

        let fullTurn = LivePoseKeypointRotation.rotatedPoint(x: 0.1, y: 0.2, clockwiseDegrees: 360)
        XCTAssertEqual(fullTurn.x, 0.1)
        XCTAssertEqual(fullTurn.y, 0.2)
    }

    /// Four quarter-turns compose to the identity, which pins the four cases against each other.
    func testFourQuarterTurnsComposeToIdentity() {
        var point = (x: Float(0.3), y: Float(0.7))
        for _ in 0..<4 {
            point = LivePoseKeypointRotation.rotatedPoint(x: point.x, y: point.y, clockwiseDegrees: 90)
        }
        XCTAssertEqual(point.x, 0.3, accuracy: 1e-6)
        XCTAssertEqual(point.y, 0.7, accuracy: 1e-6)
    }

    func testRotatedKeypointsKeepNameAndConfidence() {
        let source = [PoseKeypoint(name: "nose", y: 0.2, x: 0.1, confidence: 0.85)]

        let rotated = LivePoseKeypointRotation.rotated(source, clockwiseDegrees: 90)

        XCTAssertEqual(rotated.count, 1)
        XCTAssertEqual(rotated[0].name, "nose")
        XCTAssertEqual(rotated[0].confidence, 0.85)
        XCTAssertEqual(rotated[0].x, 0.8, accuracy: 1e-6)
        XCTAssertEqual(rotated[0].y, 0.1, accuracy: 1e-6)
    }

    // MARK: - Metrics

    func testMetricsSummaryLeadsWithTheGateFigures() {
        var metrics = LivePoseMetrics()
        metrics.framesKept = 1800
        metrics.framesInferred = 1798
        metrics.recordingDuration = 180
        metrics.queueDrops = 2
        metrics.maxQueueDepth = 5
        metrics.lateFrameDrops = 3
        metrics.preprocess.record(0.006)
        metrics.inference.record(0.040)
        metrics.inference.record(0.060)

        let line = metrics.summaryLine

        XCTAssertEqual(metrics.samplesPerSecond, 10, accuracy: 1e-9)
        XCTAssertTrue(line.hasPrefix("Live: 1800 samples in 180.0 s (10.0/s)"), line)
        XCTAssertTrue(line.contains("inferred 1798"), line)
        XCTAssertTrue(line.contains("queue drops 2 (max depth 5)"), line)
        XCTAssertTrue(line.contains("late frames 3"), line)
        XCTAssertTrue(line.contains("preprocess 6.0 ms avg / 6.0 max"), line)
        XCTAssertTrue(line.contains("inference 50.0 ms avg / 60.0 max"), line)
        XCTAssertFalse(line.contains("cancelled"), line)
        XCTAssertFalse(line.contains("critical"), line)
    }

    func testMetricsSummaryNamesTheAbnormalEndings() {
        var metrics = LivePoseMetrics()
        metrics.stoppedForThermal = true
        metrics.wasCancelled = true
        metrics.preprocessFailures = 1

        let line = metrics.summaryLine

        XCTAssertTrue(line.contains("stopped: critical thermal state"), line)
        XCTAssertTrue(line.contains("cancelled"), line)
        XCTAssertTrue(line.contains("preprocess failures 1"), line)
        XCTAssertEqual(metrics.samplesPerSecond, 0, "no duration means no rate, not a division by zero")
    }

    // MARK: - Channel

    func testChannelDeliversInOrderAndDrainsAfterFinish() async {
        let channel = LivePoseSampleChannel(capacity: 10)
        for index in 0..<3 {
            channel.push(sample(index))
        }
        channel.finish()

        var received: [Int] = []
        while let next = await channel.next() {
            received.append(next.frameIndex)
        }

        XCTAssertEqual(received, [0, 1, 2], "finish() lets the consumer drain what was queued")
        XCTAssertFalse(channel.isCancelled)
        XCTAssertEqual(channel.stats, .init(dropCount: 0, maxDepth: 3, pushCount: 3))
    }

    func testChannelWakesAParkedConsumerWithTheNextPush() async {
        let channel = LivePoseSampleChannel(capacity: 10)

        let consumer = Task { await channel.next()?.frameIndex }
        // Let the consumer park before anything is pushed. If it had not parked yet, push() would
        // simply queue and next() would find the element — either way the assertion holds.
        try? await Task.sleep(nanoseconds: 20_000_000)
        channel.push(sample(7))

        let received = await consumer.value
        XCTAssertEqual(received, 7)
    }

    func testChannelCancelDropsWhatIsQueued() async {
        let channel = LivePoseSampleChannel(capacity: 10)
        channel.push(sample(0))
        channel.push(sample(1))

        channel.cancel()
        channel.push(sample(2))

        let next = await channel.next()
        XCTAssertNil(next, "cancel() discards queued samples and refuses later ones")
        XCTAssertTrue(channel.isCancelled)
        XCTAssertEqual(channel.stats.pushCount, 2, "a push after cancel is not counted as queued work")
    }

    func testChannelShedsTheOldestSampleWhenFull() async {
        let channel = LivePoseSampleChannel(capacity: 2)
        channel.push(sample(0))
        channel.push(sample(1))
        channel.push(sample(2))
        channel.finish()

        var received: [Int] = []
        while let next = await channel.next() {
            received.append(next.frameIndex)
        }

        XCTAssertEqual(received, [1, 2])
        XCTAssertEqual(channel.stats.dropCount, 1)
        XCTAssertEqual(channel.stats.maxDepth, 2)
    }

    // MARK: - Recording (drain loop)

    func testRecordingScoresEverySampleInOrderAndMergesMetrics() async {
        let channel = LivePoseSampleChannel(capacity: 10)
        let streamed = StreamedResults()
        // Queued before the consumer exists, so the queue's high-water mark is deterministic:
        // a parked consumer takes a push directly and it never counts as depth.
        for index in 0..<3 {
            channel.push(sample(index))
        }
        let recording = LivePoseRecording(
            inference: { _ in [PoseKeypoint(name: "nose", y: 0.2, x: 0.1, confidence: 0.9)] },
            channel: channel,
            onResult: { result in streamed.append(result) })
        var producer = LivePoseMetrics()
        producer.framesKept = 3
        producer.recordingDuration = 0.3
        recording.finish(producer: producer)

        let outcome = await recording.outcome()

        XCTAssertEqual(outcome.results.map(\.frameIndex), [0, 1, 2])
        // Each result also went to the live consumer, unmodified, as it was scored.
        XCTAssertEqual(streamed.frameIndices, [0, 1, 2])
        XCTAssertEqual(streamed.firstKeypointX, 0.1, accuracy: 1e-6)
        XCTAssertEqual(outcome.results.map(\.timestamp), [0, 0.1, 0.2])
        XCTAssertNil(outcome.errorMessage)
        XCTAssertFalse(outcome.metrics.wasCancelled)
        XCTAssertEqual(outcome.metrics.framesKept, 3, "the capture side's figures survive the merge")
        XCTAssertEqual(outcome.metrics.framesInferred, 3)
        XCTAssertEqual(outcome.metrics.inference.count, 3)
        XCTAssertEqual(outcome.metrics.maxQueueDepth, 3)
        // Keypoints pass through the drain unmodified: uprighting happens in
        // PoseInputPreparer, before inference, not as a post-hoc rotation here.
        XCTAssertEqual(outcome.results[0].keypoints[0].x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(outcome.results[0].keypoints[0].y, 0.2, accuracy: 1e-6)
    }

    /// A model failure is a reviewable ending, not an abandoned one: the error is reported and
    /// `wasCancelled` stays false so the camera screen presents the review instead of skipping it.
    func testRecordingReportsAnInferenceFailureWithoutClaimingCancellation() async {
        let channel = LivePoseSampleChannel(capacity: 10)
        let recording = LivePoseRecording(
            inference: { input in
                guard input.tensor.isEmpty else { throw PoseError.inferenceFailed("op unsupported") }
                return []
            },
            channel: channel)
        channel.push(sample(0))
        channel.push(LivePoseSample(frameIndex: 1, timestamp: 0.1, input: PoseModelInput(
            tensor: Data([1]), mapping: sample(0).input.mapping)))
        channel.push(sample(2))
        recording.finish(producer: LivePoseMetrics())

        let outcome = await recording.outcome()

        XCTAssertEqual(outcome.results.map(\.frameIndex), [0], "scoring stops at the failure")
        XCTAssertEqual(outcome.errorMessage, "Pose inference failed: op unsupported")
        XCTAssertFalse(outcome.metrics.wasCancelled)
        XCTAssertEqual(outcome.metrics.framesInferred, 1)
    }

    func testRecordingCancelledMidDrainIsMarkedCancelled() async {
        let channel = LivePoseSampleChannel(capacity: 10)
        let recording = LivePoseRecording(inference: { _ in [] }, channel: channel)
        var producer = LivePoseMetrics()
        producer.framesKept = 5
        recording.cancel(producer: producer)

        let outcome = await recording.outcome()

        XCTAssertTrue(outcome.metrics.wasCancelled)
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.metrics.framesKept, 5, "what the capture side measured is kept")
        XCTAssertTrue(outcome.results.isEmpty)
    }

    // MARK: - Coverage

    /// A clean 3 s take at 10 samples/s lays down 31 grid slots; 29 or more scored counts as
    /// complete, since the first and last slots can straddle the file's own start and end.
    func testCoverageAcceptsACleanRecordingWithinTheSampleTolerance() {
        XCTAssertEqual(LivePoseCoverage.expectedSamples(duration: 3.0), 31)
        XCTAssertEqual(LivePoseCoverage.expectedSamples(duration: 0), 0)

        XCTAssertTrue(LivePoseCoverage.isComplete(outcome(kept: 31, inferred: 31, duration: 3.0)))
        XCTAssertTrue(LivePoseCoverage.isComplete(outcome(kept: 29, inferred: 29, duration: 3.0)))
        XCTAssertFalse(
            LivePoseCoverage.isComplete(outcome(kept: 28, inferred: 28, duration: 3.0)),
            "three missing slots is a gap the detector would feel")
    }

    /// Every way a recording can fall short of the file path sends it through Processing.
    func testCoverageRejectsEveryIncompleteEnding() {
        let clean = outcome(kept: 31, inferred: 31, duration: 3.0)
        XCTAssertTrue(LivePoseCoverage.isComplete(clean), "the baseline must pass for the rejections to mean anything")

        let rejected: [(String, LivePoseOutcome)] = [
            ("a queue drop", outcome(kept: 31, inferred: 31, duration: 3.0) { $0.queueDrops = 1 }),
            ("a preprocess failure", outcome(kept: 31, inferred: 31, duration: 3.0) { $0.preprocessFailures = 1 }),
            ("a thermal stop", outcome(kept: 31, inferred: 31, duration: 3.0) { $0.stoppedForThermal = true }),
            ("time at serious", outcome(kept: 31, inferred: 31, duration: 3.0) { $0.secondsAtSerious = 0.5 }),
            ("cancellation", outcome(kept: 31, inferred: 31, duration: 3.0) { $0.wasCancelled = true }),
            ("a kept sample never scored", outcome(kept: 31, inferred: 30, duration: 3.0)),
            ("an inference error", outcome(kept: 31, inferred: 31, duration: 3.0, errorMessage: "op unsupported")),
            ("nothing scored", outcome(kept: 0, inferred: 0, duration: 0))
        ]
        for (reason, outcome) in rejected {
            XCTAssertFalse(LivePoseCoverage.isComplete(outcome), "\(reason) must send the take through Processing")
        }
    }

    /// The sensor is landscape; a portrait movie connection turns it a quarter-turn, so the size
    /// the live keypoints are normalized against transposes.
    func testRenderedPixelSizeTransposesForAQuarterTurn() {
        XCTAssertEqual(
            LivePoseCoverage.renderedPixelSize(sensorWidth: 1920, sensorHeight: 1080, movieRotationDegrees: 90),
            CGSize(width: 1080, height: 1920))
        XCTAssertEqual(
            LivePoseCoverage.renderedPixelSize(sensorWidth: 1920, sensorHeight: 1080, movieRotationDegrees: 270),
            CGSize(width: 1080, height: 1920))
        XCTAssertEqual(
            LivePoseCoverage.renderedPixelSize(sensorWidth: 1920, sensorHeight: 1080, movieRotationDegrees: 0),
            CGSize(width: 1920, height: 1080))
        XCTAssertEqual(
            LivePoseCoverage.renderedPixelSize(sensorWidth: 1920, sensorHeight: 1080, movieRotationDegrees: 180),
            CGSize(width: 1920, height: 1080))
    }

    // MARK: - Overlay geometry

    /// Only confident joints are drawn, and a limb needs both of its joints; the conversion the
    /// caller supplies is applied to every emitted point.
    func testOverlayGeometryDrawsConfidentJointsAndFullyConfidentLimbs() {
        let keypoints = [
            PoseKeypoint(name: "left_shoulder", y: 0.2, x: 0.1, confidence: 0.9),
            PoseKeypoint(name: "right_shoulder", y: 0.2, x: 0.3, confidence: 0.9),
            PoseKeypoint(name: "left_elbow", y: 0.4, x: 0.05, confidence: 0.1),
            PoseKeypoint(name: "left_hip", y: 0.5, x: 0.12, confidence: 0.8)
        ]

        // Rounded: a `Float` 0.1 widened to `CGFloat` is 0.10000000149, and the assertion is about
        // which points are emitted, not about the widening.
        let geometry = LivePoseOverlayGeometry(keypoints: keypoints) { keypoint in
            CGPoint(x: (CGFloat(keypoint.x) * 100).rounded(), y: (CGFloat(keypoint.y) * 100).rounded())
        }

        XCTAssertEqual(geometry.joints.count, 3, "the low-confidence elbow is not drawn")
        XCTAssertEqual(geometry.joints[0], CGPoint(x: 10, y: 20))
        XCTAssertEqual(
            geometry.limbs,
            [
                .init(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 30, y: 20)),
                .init(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 12, y: 50))
            ],
            "shoulder-shoulder and left shoulder-hip are drawable; shoulder-elbow is not")
    }

    // MARK: - Fixtures

    /// A recording outcome with the figures the coverage rule reads, plus any single-field
    /// override for the rejection cases.
    private func outcome(
        kept: Int, inferred: Int, duration: TimeInterval, errorMessage: String? = nil,
        adjust: (inout LivePoseMetrics) -> Void = { _ in }
    ) -> LivePoseOutcome {
        var metrics = LivePoseMetrics()
        metrics.framesKept = kept
        metrics.framesInferred = inferred
        metrics.recordingDuration = duration
        adjust(&metrics)
        return LivePoseOutcome(results: [], metrics: metrics, errorMessage: errorMessage)
    }

    /// Collects what the recording's live result handler receives. A class with a lock rather
    /// than an actor: the handler is synchronous and called from the drain's task.
    private final class StreamedResults: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [PoseFrameResult] = []

        func append(_ result: PoseFrameResult) {
            lock.lock()
            defer { lock.unlock() }
            results.append(result)
        }

        var frameIndices: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return results.map(\.frameIndex)
        }

        var firstKeypointX: Float {
            lock.lock()
            defer { lock.unlock() }
            return results.first?.keypoints.first?.x ?? .nan
        }
    }

    private func sample(_ index: Int) -> LivePoseSample {
        LivePoseSample(
            frameIndex: index,
            timestamp: Double(index) / 10,
            input: PoseModelInput(
                tensor: Data(),
                mapping: LetterboxMapping(
                    scale: 1, offsetX: 0, offsetY: 0,
                    inputSize: CGSize(width: 256, height: 256),
                    sourceExtent: CGRect(x: 0, y: 0, width: 256, height: 256))))
    }
}
