import XCTest
@testable import Turnip

/// The trick model's input, its decoding and the client's postprocessing (`MODEL_CONTRACT.md`
/// §3.1–§3.4), as pure functions over hand-made values.
final class TrickModelTests: XCTestCase {
    private let descriptor = TrickModelDescriptor(
        classes: ["background", "cork", "gainer", "cork+gainer"], windowFrames: 16, windowStride: 8)

    private func row(_ winner: Int, _ probability: Float) -> [Float] {
        var row = [Float](repeating: (1 - probability) / 3, count: 4)
        row[winner] = probability
        return row
    }

    private func segment(
        _ start: Int, _ end: Int, _ score: Float, _ names: [String] = ["cork"], nameScores: [Float]? = nil
    ) -> TrickSegment {
        TrickSegment(
            startFrame: start, endFrame: end, score: score, trickNames: names,
            nameScores: nameScores ?? names.map { _ in score })
    }

    // MARK: - Decoding (§3.2.1)

    func testWindowCountFollowsTheContractsFormula() {
        XCTAssertEqual(descriptor.windowCount(frameCount: 15), 0)
        XCTAssertEqual(descriptor.windowCount(frameCount: 16), 1)
        XCTAssertEqual(descriptor.windowCount(frameCount: 23), 1)
        XCTAssertEqual(descriptor.windowCount(frameCount: 24), 2)
        XCTAssertEqual(descriptor.windowCount(frameCount: 600), 74)
    }

    /// A run of windows with one class is one segment from the first window's start to the last
    /// one's end, scored by the mean of the winning probability; background is never a segment.
    func testConsecutiveWindowsOfOneClassBecomeOneSegment() {
        let segments = descriptor.segments(windowProbabilities: [
            row(0, 0.9), row(1, 0.9), row(1, 0.7), row(0, 0.8), row(2, 0.6)
        ])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].startFrame, 8)
        XCTAssertEqual(segments[0].endFrame, 32)
        XCTAssertEqual(segments[0].score, 0.8, accuracy: 1e-6)
        XCTAssertEqual(segments[0].trickNames, ["cork"])
        XCTAssertEqual(segments[1].startFrame, 32)
        XCTAssertEqual(segments[1].endFrame, 48)
        XCTAssertEqual(segments[1].trickNames, ["gainer"])
    }

    func testTwoClassesBackToBackAreTwoSegments() {
        let segments = descriptor.segments(windowProbabilities: [row(1, 0.9), row(2, 0.9)])
        XCTAssertEqual(segments.map(\.trickNames), [["cork"], ["gainer"]])
        XCTAssertEqual(segments.map(\.endFrame), [16, 24])
    }

    /// A combo is one class; its names are the class split on the separator, each carrying the
    /// segment's score.
    func testAComboClassSplitsIntoItsNames() {
        let segment = descriptor.segments(windowProbabilities: [row(3, 0.75)]).first
        XCTAssertEqual(segment?.trickNames, ["cork", "gainer"])
        XCTAssertEqual(segment?.nameScores, [0.75, 0.75])
    }

    /// An exact tie goes to the first class, as numpy's argmax breaks it in training.
    func testATieGoesToTheFirstClass() {
        XCTAssertEqual(descriptor.segments(windowProbabilities: [[0.4, 0.4, 0.1, 0.1]]), [])
        XCTAssertEqual(
            descriptor.segments(windowProbabilities: [[0.1, 0.4, 0.4, 0.1]]).first?.trickNames, ["cork"])
    }

    func testASegmentsWindowIsItsFramesAtTenHertz() {
        XCTAssertEqual(segment(120, 175, 0.9).window, TrickWindow(startTime: 12, endTime: 17.5))
    }

    // MARK: - Postprocessing (§3.3 steps 1–3)

    func testSegmentsBelowTheThresholdAreDropped() {
        let rules = TrickProposalRules()
        XCTAssertEqual(rules.segments(from: [segment(0, 16, 0.49), segment(40, 56, 0.5)]).map(\.startFrame), [40])
    }

    /// Suppression ignores names: of two segments overlapping by more than half, only the surer stays.
    func testSuppressionKeepsTheHigherScoreWhateverTheNames() {
        let rules = TrickProposalRules()
        let kept = rules.segments(from: [
            segment(2, 22, 0.6, ["gainer"]), segment(0, 20, 0.9, ["cork"]), segment(10, 30, 0.7, ["gainer"])
        ])
        XCTAssertEqual(kept.map(\.startFrame), [0, 10])
        XCTAssertEqual(kept.map(\.trickNames), [["cork"], ["gainer"]])
    }

    func testAnOverlapOfExactlyHalfIsNotSuppressed() {
        let rules = TrickProposalRules()
        XCTAssertEqual(TrickProposalRules.overlap(segment(0, 30, 0.9), segment(10, 40, 0.6)), 0.5)
        XCTAssertEqual(
            rules.segments(from: [segment(0, 30, 0.9, ["cork"]), segment(10, 40, 0.6, ["gainer"])]).count, 2)
    }

    /// Fewer than five frames apart, segments with the same names are one, spanning both and as
    /// sure as the surer part; five apart, or with other names, they stay two.
    func testSameNamesFewerThanFiveFramesApartMerge() {
        let rules = TrickProposalRules()
        let merged = rules.segments(from: [segment(0, 16, 0.6), segment(20, 36, 0.8)])
        XCTAssertEqual(merged, [segment(0, 36, 0.8)])

        XCTAssertEqual(rules.segments(from: [segment(0, 16, 0.6), segment(21, 37, 0.8)]).count, 2)
        XCTAssertEqual(
            rules.segments(from: [segment(0, 16, 0.6, ["cork"]), segment(16, 32, 0.8, ["gainer"])]).count, 2)
    }

    func testAMergeReachesPastASegmentWithOtherNames() {
        let rules = TrickProposalRules()
        let result = rules.segments(from: [
            segment(0, 16, 0.6), segment(12, 22, 0.7, ["gainer"]), segment(18, 34, 0.8)
        ])
        XCTAssertEqual(result, [segment(0, 34, 0.8), segment(12, 22, 0.7, ["gainer"])])
    }

    func testAMergedSegmentKeepsEachNamesHigherScore() {
        let rules = TrickProposalRules()
        let names = ["cork", "gainer"]
        let merged = rules.segments(from: [
            segment(0, 16, 0.6, names, nameScores: [0.6, 0.3]), segment(18, 34, 0.7, names, nameScores: [0.4, 0.7])
        ])
        XCTAssertEqual(merged.first?.nameScores, [0.6, 0.7])
    }

    // MARK: - Pre-fill, blind sample, provenance (§3.3 steps 4–6)

    func testOnlyNamesAtOrAboveTheBarArePrefilled() {
        let rules = TrickProposalRules(blindSampleRate: 0)
        var generator = SplitMix64(seed: 1)
        let proposal = rules.proposal(
            for: segment(0, 16, 0.9, ["cork", "gainer"], nameScores: [0.5, 0.49]),
            modelVersion: "trick-v1.3", using: &generator)
        XCTAssertEqual(
            proposal, ModelProposal(modelVersion: "trick-v1.3", suggestedNames: ["cork"], suggestionsWithheld: false))
        XCTAssertEqual(proposal.prefilledNames, [ClipName(name: "cork", origin: .model)])
    }

    /// A segment none of whose names clears the bar is still a proposal, just a window with no names.
    func testASegmentWithNoConfidentNameIsStillProposed() {
        let rules = TrickProposalRules(blindSampleRate: 0)
        var generator = SplitMix64(seed: 1)
        let proposal = rules.proposal(
            for: segment(0, 16, 0.6, ["cork"], nameScores: [0.3]), modelVersion: "v", using: &generator)
        XCTAssertEqual(proposal.suggestedNames, [])
        XCTAssertEqual(proposal.prefilledNames, [])
    }

    /// A blind clip starts with no names but records the ones it would have had.
    func testABlindClipRecordsItsNamesButStartsWithoutThem() {
        let rules = TrickProposalRules(blindSampleRate: 1)
        var generator = SplitMix64(seed: 1)
        let proposal = rules.proposal(for: segment(0, 16, 0.9), modelVersion: "v", using: &generator)
        XCTAssertTrue(proposal.suggestionsWithheld)
        XCTAssertEqual(proposal.suggestedNames, ["cork"])
        XCTAssertEqual(proposal.prefilledNames, [])
    }

    func testAboutATenthOfClipsAreDrawnBlind() {
        let rules = TrickProposalRules()
        var generator = SplitMix64(seed: 7)
        let blind = (0..<10_000).filter { _ in
            rules.proposal(for: segment(0, 16, 0.9), modelVersion: "v", using: &generator).suggestionsWithheld
        }.count
        XCTAssertTrue((900...1_100).contains(blind), "\(blind) of 10,000 drawn blind")
    }

    // MARK: - Input (§3.1, §3.4)

    private func slot(_ value: Float) -> [Float] { Array(repeating: value, count: 51) }

    func testATenHertzGridPassesThrough() {
        let slots: [[Float]?] = [slot(0.1), nil, slot(0.3)]
        XCTAssertEqual(ContributionPose(sampleRate: 10, slots: slots).canonicalSlots, slots)
    }

    /// 20 Hz down to 10: every canonical time lands on a grid slot, which is copied as it is.
    func testDownsamplingCopiesTheSlotsTheCanonicalTimesLandOn() {
        let pose = ContributionPose(sampleRate: 20, slots: [slot(0), slot(1), nil, slot(3), slot(4)])
        XCTAssertEqual(pose.canonicalSlots, [slot(0), nil, slot(4)])
    }

    /// 4 Hz up to 10: in between grid slots the values are interpolated, and a canonical frame
    /// touching a gap is a gap.
    func testUpsamplingInterpolatesAndGapsBreakIt() throws {
        let pose = ContributionPose(sampleRate: 4, slots: [slot(0), slot(1), slot(2)])
        let canonical = pose.canonicalSlots
        XCTAssertEqual(canonical.count, 6)
        let firsts = try canonical.map { try XCTUnwrap($0?.first) }
        for (value, expected) in zip(firsts, [0, 0.4, 0.8, 1.2, 1.6, 2] as [Float]) {
            XCTAssertEqual(value, expected, accuracy: 1e-6)
        }

        let gapped = ContributionPose(sampleRate: 4, slots: [slot(0), nil, slot(2)]).canonicalSlots
        XCTAssertEqual(gapped.map { $0 == nil }, [false, true, true, true, true, false])
    }

    /// Each row is the slot's 51 values and a 0, or 51 zeros and the gap indicator's 1.
    func testInputRowsCarryTheGapIndicator() {
        let input = TrickModelInput(canonicalSlots: [slot(0.5), nil])
        XCTAssertEqual(input.frameCount, 2)
        XCTAssertEqual(input.values, slot(0.5) + [0] + slot(0) + [1])
    }

    /// A frame with no keypoint over the pose model's confidence floor is a gap, as contribution
    /// encodes it.
    func testAFrameWithNoConfidentKeypointIsAGap() throws {
        func frame(_ index: Int, confidence: Float) -> PoseFrameResult {
            PoseFrameResult(
                frameIndex: index, timestamp: Double(index) / 10,
                keypoints: PoseKeypoint.names.map { PoseKeypoint(name: $0, y: 0.25, x: 0.75, confidence: confidence) })
        }
        let input = try XCTUnwrap(TrickModelInput(
            frames: [frame(0, confidence: 0.9), frame(1, confidence: 0.1), frame(2, confidence: 0.9)], duration: nil))
        XCTAssertEqual(input.frameCount, 3)
        XCTAssertEqual(Array(input.values[0..<3]), [0.75, 0.25, 0.9])
        XCTAssertEqual(input.values[51], 0)
        XCTAssertEqual(input.values[52 + 51], 1)
        XCTAssertEqual(Array(input.values[52..<(52 + 51)]), slot(0))
    }
}

/// A seeded generator, so a draw a test makes is the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
