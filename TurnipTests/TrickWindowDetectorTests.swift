import XCTest
@testable import Turnip

final class TrickWindowDetectorTests: XCTestCase {
    private let detector = TrickWindowDetector()

    // MARK: - End-to-end over synthetic pose frames

    func testDetectsASingleSustainedPeak() {
        let frames = PoseFixture.frames(hipXPositions: Self.singlePeakPositions)

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 0.4, endsAt: 5.0)
    }

    func testMergesTwoPeaksSeparatedByLessThanTheQuietMinimum() {
        let frames = PoseFixture.frames(hipXPositions: Self.twoPeakPositions(quietFramesBetween: 5))

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 1, "two halves of one trick were reported as two tricks")
        assertWindow(windows.first, startsAt: 0.9, endsAt: 6.2)
    }

    func testSeparatesTwoPeaksWithEnoughQuietBetweenThem() {
        let frames = PoseFixture.frames(hipXPositions: Self.twoPeakPositions(quietFramesBetween: 15))

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 2)
        assertWindow(windows.first, startsAt: 0.9, endsAt: 5.3)
        assertWindow(windows.last, startsAt: 2.8, endsAt: 7.2)
    }

    /// The frame in the middle of the peak loses every keypoint to blur. Interpolating its anchor
    /// keeps the run of motion intact; without it the run splits into two halves, each too short
    /// to survive the sustained-samples minimum, and the trick disappears entirely.
    func testInterpolatesThroughADroppedConfidenceFrameRatherThanSplittingTheWindow() {
        let frames = PoseFixture.frames(hipXPositions: Self.singlePeakPositions, blankFrames: [17])

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 0.4, endsAt: 5.0)
    }

    /// A one-hip dropout in the middle of the quiet stretch must not merge two tricks: the
    /// reconstructed anchor keeps the stretch quiet, so the 15-sample run clears the 10-sample
    /// minimum and both peaks survive.
    /// Negative control: without reconstruction the dropout frame anchors on the lone hip, so
    /// the samples on both sides read 0.1 — 0.067 after smoothing, above the 0.05 threshold —
    /// breaking the quiet run into 7 and 6 and folding both peaks into a single window.
    /// (The hip half-width here is 0.1 rather than 0.06: smoothing averages each
    /// spike with its quiet neighbours, so the narrower spike lands at 0.04 and the negative
    /// control would not discriminate.)
    /// Every frame carries both hips at that half-width, dropout included — the reconstruction
    /// reads the offset off the preceding full-hip frame, so the geometry has to exist there.
    func testOneHipDropoutInsideTheQuietStretchStillSeparatesTwoTricks() {
        var positions = [Float](repeating: 0.1, count: 20)
        positions += [0.2, 0.3, 0.4, 0.5]
        positions += [Float](repeating: 0.5, count: 15)
        positions += [0.6, 0.7, 0.8, 0.9]
        positions += [Float](repeating: 0.9, count: 12)

        let dropoutIndex = 20 + 4 + 7
        let frames = positions.enumerated().map { index, x in
            PoseFixture.frame(
                index: index,
                hip: nil,
                leftHip: KeypointSeed(x: x - 0.1, y: 0.5, confidence: 0.9),
                rightHip: KeypointSeed(x: x + 0.1, y: 0.5, confidence: index == dropoutIndex ? 0.1 : 0.9)
            )
        }

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 2, "the dropout's spurious motion merged two tricks into one")
    }

    /// A one-hip dropout that outlasts the 3-frame reconstruction bound inserts a lone
    /// unknown sample where the anchor identity degrades — and that seam must not split the
    /// burst around it. The burst is 5 motion samples wide with a 6-frame dropout (snapshot
    /// 4 frames back at the seam), so the signal around it reads M M U M M before and after
    /// smoothing.
    /// Negative control: without the seam tolerance the run splits into [5...6] and [8...9],
    /// each below the 3-sample sustained minimum, and the trick disappears entirely — the
    /// failure mode the identity guard exists to prevent, reached through `.unknown`
    /// instead of `.moving`.
    func testOneHipDropoutLongerThanTheReconstructionBoundStillDetectsTheTrick() {
        let positions: [Float] = [Float](repeating: 0.5, count: 6)
            + [0.6, 0.7, 0.8, 0.9, 1.0]
            + [Float](repeating: 1.0, count: 4)

        let frames = positions.enumerated().map { index, x in
            PoseFixture.frame(
                index: index,
                hip: nil,
                leftHip: KeypointSeed(x: x - 0.1, y: 0.5, confidence: 0.9),
                rightHip: KeypointSeed(x: x + 0.1, y: 0.5, confidence: (5...10).contains(index) ? 0.1 : 0.9)
            )
        }

        let windows = detector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))

        XCTAssertEqual(windows.count, 1, "the identity seam split the burst below the sustained minimum")
        assertWindow(windows.first, startsAt: 0, endsAt: 4.0)
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

    // MARK: - Sample-rate derivation (Settings screen's analysis granularity)

    func testDefaultThresholdsMatchTheShippedTenSamplesPerSecondRate() {
        let atDefaultRate = TrickWindowDetector(sampleRate: 10)

        XCTAssertEqual(atDefaultRate.minimumSustainedSamples, 3)
        XCTAssertEqual(atDefaultRate.minimumQuietSamples, 10)
    }

    /// At 30 samples/sec the same 300 ms / 1 s durations are 9 and 30 samples, not the fixed 3
    /// and 10 a rate-naive default would keep — a burst that would have counted as sustained at
    /// the default rate must not also count as sustained at 3x the rate.
    func testThresholdsScaleWithTheConfiguredSampleRate() {
        let atTripleRate = TrickWindowDetector(sampleRate: 30)

        XCTAssertEqual(atTripleRate.minimumSustainedSamples, 9)
        XCTAssertEqual(atTripleRate.minimumQuietSamples, 30)
    }

    /// An explicit sample count still overrides the derivation, regardless of rate — the seam
    /// tests above (`detector`, built with no sample rate argument) lean on this staying 3 and
    /// 10 at the default rate; this pins that an explicit override wins even off that default.
    func testExplicitSampleCountsOverrideTheRateDerivation() {
        let overridden = TrickWindowDetector(minimumSustainedSamples: 1, minimumQuietSamples: 2, sampleRate: 30)

        XCTAssertEqual(overridden.minimumSustainedSamples, 1)
        XCTAssertEqual(overridden.minimumQuietSamples, 2)
    }

    func testRateDerivedThresholdsAreNeverLessThanOneSample() {
        let atMinimumGranularity = TrickWindowDetector(sampleRate: 1)

        XCTAssertEqual(atMinimumGranularity.minimumSustainedSamples, 1)
        XCTAssertEqual(atMinimumGranularity.minimumQuietSamples, 1)
    }

    /// `displacementThreshold` is a per-sample-pair *positional* delta, not a velocity, so
    /// above the shipped default rate it has to scale down the same way the sample-count
    /// thresholds above do: unscaled, doubling the sample rate halves the real ground an
    /// athlete covers between consecutive samples for identical motion, silently raising
    /// the effective speed a trick needs to clear the bar.
    func testDisplacementThresholdMatchesTheShippedRateAtTheDefaultSampleRate() {
        XCTAssertEqual(TrickWindowDetector(sampleRate: 10).displacementThreshold, 0.05, accuracy: 0.0001)
    }

    func testDisplacementThresholdScalesDownAsTheSampleRateRises() {
        XCTAssertEqual(TrickWindowDetector(sampleRate: 20).displacementThreshold, 0.025, accuracy: 0.0001)
        XCTAssertEqual(TrickWindowDetector(sampleRate: 30).displacementThreshold, Float(1) / 60, accuracy: 0.0001)
    }

    /// Below the default rate, `displacementThreshold` stays at the base 0.05 rather than
    /// also scaling up: real trick footage doesn't reliably produce the larger per-sample
    /// displacement a naive symmetric scale-up demands (0.5 at `sampleRate == 1` — half the
    /// normalized frame between two consecutive samples), so scaling up would cause
    /// "nothing detected" at the low end of the granularity range, as an unscaled threshold
    /// would at the high end.
    func testDisplacementThresholdStaysAtTheBaseValueBelowTheDefaultSampleRate() {
        XCTAssertEqual(TrickWindowDetector(sampleRate: 1).displacementThreshold, 0.05, accuracy: 0.0001)
        XCTAssertEqual(TrickWindowDetector(sampleRate: 5).displacementThreshold, 0.05, accuracy: 0.0001)
    }

    func testExplicitDisplacementThresholdOverridesTheRateDerivation() {
        let overridden = TrickWindowDetector(displacementThreshold: 0.05, sampleRate: 30)

        XCTAssertEqual(overridden.displacementThreshold, 0.05, accuracy: 0.0001)
    }

    /// At 20 samples/sec, per-sample displacement of 0.03 is real motion (roughly the
    /// same athlete speed `moving(_:)`'s 0.2 represents at the shipped 10 samples/sec
    /// default) but sits below the *unscaled* 0.05 threshold — an unscaled detector would
    /// find zero windows in this exact signal. `.count` alone wouldn't discriminate a
    /// detector that returns no windows at all from one that merges wrongly, so this also
    /// pins the window's bounds.
    func testHighSampleRateStillDetectsMotionBelowTheUnscaledThreshold() {
        let highRate = TrickWindowDetector(sampleRate: 20)
        let displacements: [Float?] = Array(repeating: 0.03, count: 8)
        let samples = displacements.enumerated().map { index, displacement in
            MotionSample(
                startTime: Double(index) / 20, endTime: Double(index + 1) / 20,
                displacement: displacement)
        }

        let windows = highRate.detectWindows(in: samples)

        XCTAssertEqual(windows.count, 1)
        assertWindow(windows.first, startsAt: 0, endsAt: 0.4 + highRate.trailingBufferSeconds)
    }

    // MARK: - Window bounds

    func testExpandsEachWindowByItsOwnLeadingAndTrailingBuffer() {
        let samples = signal(quiet(20) + moving(3) + quiet(10))

        let unbuffered = TrickWindowDetector(
            leadingBufferSeconds: 0, trailingBufferSeconds: 0
        ).detectWindows(in: samples)
        let buffered = detector.detectWindows(in: samples)

        assertWindow(unbuffered.first, startsAt: 2.0, endsAt: 2.3)
        // Discriminating: the leading and trailing edges move by different amounts —
        // the trailing buffer is larger, so a detected trick keeps playing well past
        // the moment its motion signal goes quiet instead of cutting at the landing.
        assertWindow(buffered.first, startsAt: 1.0, endsAt: 5.3)
    }

    func testClampsTheLeadingBufferAtTheStartOfTheVideo() {
        let windows = detector.detectWindows(in: signal(moving(3) + quiet(10)))

        assertWindow(windows.first, startsAt: 0, endsAt: 3.3)
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
