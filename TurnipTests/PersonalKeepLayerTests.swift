import XCTest
@testable import Turnip

/// Builds band segments and the runs they come from, for the keep layer's tests.
enum KeepFixture {
    /// One labeled band segment along `axis` (`PersonalFixture.axis`).
    static func example(
        _ score: Float, axis: Int, kept: Bool, at seconds: TimeInterval = 0, poseID: String = "pose",
        startFrame: Int = 0
    ) -> KeepExample {
        KeepExample(
            score: score, vector: PersonalFixture.axis(axis), isKept: kept,
            recordedAt: Date(timeIntervalSince1970: seconds), poseID: poseID, startFrame: startFrame)
    }

    /// `count` examples of a user who keeps tricks along axis 0 and trashes those along axis 1,
    /// whatever the central score, oldest first.
    static func pickyExamples(_ count: Int, from start: TimeInterval = 0) -> [KeepExample] {
        (0..<count).map { index in
            let kept = index.isMultiple(of: 2)
            return example(
                kept ? 0.45 : 0.6, axis: kept ? 0 : 1, kept: kept, at: start + TimeInterval(index),
                startFrame: index)
        }
    }

    /// A run whose `window_probs` decode into one segment per entry of `scores`, each a single
    /// window of 10 canonical frames along its own `axes` entry, with a background window between
    /// each two: segment `k` covers frames `[20k, 20k + 10)`.
    static func run(scores: [Float], axes: [Int], version: String = "v1", personID: Int? = nil) -> WindowEmbeddings {
        var rows: [[Float]] = []
        var probabilities: [[Float]] = []
        for (score, axis) in zip(scores, axes) {
            rows.append(PersonalFixture.axis(axis))
            probabilities.append(winning(score))
            rows.append(PersonalFixture.axis(7))
            probabilities.append([0.97, 0.01, 0.01, 0.01])
        }
        return WindowEmbeddings(
            personID: personID, modelVersion: version,
            descriptor: TrickModelDescriptor(
                classes: ["background", "cork", "gainer", "hook"], windowFrames: 10, windowStride: 10),
            rows: rows, probabilities: probabilities)
    }

    /// A row that "cork" wins with probability `score`, the rest shared so it still wins.
    private static func winning(_ score: Float) -> [Float] {
        let rest = (1 - score) / 3
        return [rest - 0.001, score, rest, rest + 0.001]
    }
}

final class PersonalKeepLayerTests: XCTestCase {
    private func layer(_ parameters: KeepLayerParameters, version: String = "v1") -> PersonalKeepLayer {
        PersonalKeepLayer(modelVersion: version, parameters: parameters)
    }

    private func segment(_ start: Int, _ end: Int, _ score: Float, _ names: [String] = ["cork"]) -> TrickSegment {
        TrickSegment(
            startFrame: start, endFrame: end, score: score, trickNames: names, nameScores: names.map { _ in score })
    }

    // MARK: - The model (§4.3)

    /// The prior is the central model: a band segment is proposed at 0.5 and above, exactly as
    /// `MODEL_CONTRACT.md` §3.3 step 1 has it.
    func testThePriorIsTheCentralThreshold() {
        let prior = layer(.prior(width: 8))
        for score: Float in [0.5, 0.55, 0.69] {
            XCTAssertEqual(prior.keeps(score: score, vector: PersonalFixture.axis(0)), true, "\(score)")
        }
        for score: Float in [0.3, 0.45, 0.49] {
            XCTAssertEqual(prior.keeps(score: score, vector: PersonalFixture.axis(0)), false, "\(score)")
        }
    }

    func testScoresAreClampedSoTheLogitStaysFinite() {
        XCTAssertEqual(KeepLayerParameters.logit(0), KeepLayerParameters.logit(0.01))
        XCTAssertEqual(KeepLayerParameters.logit(1), KeepLayerParameters.logit(0.99))
        XCTAssertTrue(KeepLayerParameters.logit(1).isFinite)
    }

    func testAnEmbeddingOfAnotherWidthIsLeftToTheCentralRule() {
        XCTAssertNil(layer(.prior(width: 8)).keeps(score: 0.6, vector: [1, 0]))
    }

    // MARK: - The fit

    func testWithNoExamplesTheFitIsThePrior() {
        XCTAssertEqual(KeepLayerFit.fit([], width: 8), .prior(width: 8))
    }

    /// At the fit's answer the objective's gradient, `Xᵀ(p − y) + 2λ(θ − θ₀)`, is zero.
    func testTheFitIsTheObjectivesMinimum() {
        let examples = KeepFixture.pickyExamples(30) + [
            KeepFixture.example(0.65, axis: 0, kept: false), KeepFixture.example(0.35, axis: 1, kept: true),
            KeepFixture.example(0.5, axis: 2, kept: true), KeepFixture.example(0.5, axis: 2, kept: false)
        ]
        let fitted = KeepLayerFit.fit(examples, width: 8, penalty: 1)
        let theta = [fitted.scale, fitted.offset] + fitted.weights
        let prior: [Double] = [1, 0] + Array(repeating: 0, count: 8)
        var gradient = zip(theta, prior).map { 2 * ($0 - $1) }
        for example in examples {
            let features: [Double] = [KeepLayerParameters.logit(example.score), 1] + example.vector.map(Double.init)
            let margin = zip(theta, features).reduce(0.0) { $0 + $1.0 * $1.1 }
            let residual = 1 / (1 + exp(-margin)) - (example.isKept ? 1 : 0)
            for index in gradient.indices {
                gradient[index] += residual * features[index]
            }
        }
        XCTAssertLessThan(gradient.map(abs).max() ?? 1, 1e-6)
    }

    /// A penalty large enough leaves the layer the central model, whatever the user did.
    func testAHeavyPenaltyKeepsTheCentralModel() {
        let fitted = KeepLayerFit.fit(KeepFixture.pickyExamples(40), width: 8, penalty: 1e9)
        XCTAssertEqual(fitted.scale, 1, accuracy: 1e-6)
        XCTAssertEqual(fitted.offset, 0, accuracy: 1e-6)
        XCTAssertLessThan(fitted.weights.map(abs).max() ?? 1, 1e-6)
    }

    /// The `w` term learns what the user is picky about: here they keep one kind of trick and trash
    /// another, whatever the central model makes of either.
    func testTheLayerLearnsWhatTheUserKeeps() {
        let fitted = layer(KeepLayerFit.fit(KeepFixture.pickyExamples(40), width: 8))
        XCTAssertEqual(fitted.keeps(score: 0.4, vector: PersonalFixture.axis(0)), true)
        XCTAssertEqual(fitted.keeps(score: 0.65, vector: PersonalFixture.axis(1)), false)
    }

    /// The `a, b` terms learn how picky the user is: one who trashes everything the central model
    /// is lukewarm about raises the bar.
    func testTheLayerLearnsHowPickyTheUserIs() {
        let examples = (0..<40).map { index -> KeepExample in
            let kept = index.isMultiple(of: 2)
            return KeepFixture.example(kept ? 0.68 : 0.52, axis: 0, kept: kept, at: TimeInterval(index))
        }
        let fitted = layer(KeepLayerFit.fit(examples, width: 8))
        XCTAssertEqual(fitted.keeps(score: 0.52, vector: PersonalFixture.axis(0)), false)
        XCTAssertEqual(fitted.keeps(score: 0.68, vector: PersonalFixture.axis(0)), true)
    }

    /// Labels a line can split exactly would drive an unpenalized fit to infinity; the fit stays
    /// finite and still splits them.
    func testSeparableExamplesStayFinite() {
        let fitted = KeepLayerFit.fit(KeepFixture.pickyExamples(60), width: 8, penalty: 1e-6)
        XCTAssertTrue(([fitted.scale, fitted.offset] + fitted.weights).allSatisfy(\.isFinite))
        XCTAssertEqual(layer(fitted).keeps(score: 0.45, vector: PersonalFixture.axis(0)), true)
        XCTAssertEqual(layer(fitted).keeps(score: 0.6, vector: PersonalFixture.axis(1)), false)
    }

    func testAnExampleOfAnotherWidthIsLeftOut() {
        let odd = KeepExample(
            score: 0.6, vector: [1, 0], isKept: true, recordedAt: Date(), poseID: "pose", startFrame: 0)
        XCTAssertEqual(KeepLayerFit.fit([odd], width: 8), .prior(width: 8))
    }

    // MARK: - The gate (§5)

    func testTooFewExamplesAreNotMeasured() {
        XCTAssertNil(KeepLayerGate.outcome(of: KeepFixture.pickyExamples(19), width: 8))
        XCTAssertNotNil(KeepLayerGate.outcome(of: KeepFixture.pickyExamples(20), width: 8))
    }

    func testTooFewOfEitherLabelAreNotMeasured() {
        let mostlyKept = (0..<26).map { KeepFixture.example(0.6, axis: 0, kept: $0 >= 4, at: TimeInterval($0)) }
        XCTAssertNil(KeepLayerGate.outcome(of: mostlyKept, width: 8))
        let mostlyTrashed = (0..<26).map { KeepFixture.example(0.6, axis: 0, kept: $0 < 4, at: TimeInterval($0)) }
        XCTAssertNil(KeepLayerGate.outcome(of: mostlyTrashed, width: 8))
    }

    /// The newest fifth is held out, rounded up, and never fewer than five.
    func testTheNewestFifthIsHeldOut() {
        XCTAssertEqual(KeepLayerGate.outcome(of: KeepFixture.pickyExamples(20), width: 8)?.heldOut, 5)
        XCTAssertEqual(KeepLayerGate.outcome(of: KeepFixture.pickyExamples(26), width: 8)?.heldOut, 6)
        XCTAssertEqual(KeepLayerGate.outcome(of: KeepFixture.pickyExamples(40), width: 8)?.heldOut, 8)
    }

    func testALayerThatPredictsTheNewestSegmentsPasses() throws {
        let outcome = try XCTUnwrap(KeepLayerGate.outcome(of: KeepFixture.pickyExamples(40), width: 8))
        XCTAssertLessThan(outcome.personalLoss, outcome.centralLoss)
        XCTAssertTrue(outcome.passes)
    }

    /// What the user did before is no guide to the newest segments here: they changed their mind,
    /// so the layer loses to the central model and stays off.
    func testALayerThatMispredictsTheNewestSegmentsFails() throws {
        let older = KeepFixture.pickyExamples(32)
        let newer = (0..<8).map { index -> KeepExample in
            let kept = !index.isMultiple(of: 2)
            return KeepFixture.example(kept ? 0.6 : 0.45, axis: kept ? 1 : 0, kept: kept, at: 100 + TimeInterval(index))
        }
        let outcome = try XCTUnwrap(KeepLayerGate.outcome(of: older + newer, width: 8))
        XCTAssertEqual(outcome.heldOut, 8)
        XCTAssertFalse(outcome.passes)
    }

    /// A layer no better than the central model adds nothing, so a tie leaves it off.
    func testATieLeavesTheLayerOff() {
        XCTAssertFalse(
            KeepLayerGate.Outcome(examples: 40, heldOut: 8, personalLoss: 0.6, centralLoss: 0.6).passes)
        XCTAssertTrue(
            KeepLayerGate.Outcome(examples: 40, heldOut: 8, personalLoss: 0.59, centralLoss: 0.6).passes)
    }

    /// Examples recorded at the same moment keep one order, so the same library always holds out
    /// the same segments.
    func testTheHoldoutIsTheSameWhateverOrderTheExamplesCome() {
        let examples = KeepFixture.pickyExamples(30).map {
            KeepExample(
                score: $0.score, vector: $0.vector, isKept: $0.isKept, recordedAt: Date(timeIntervalSince1970: 0),
                poseID: $0.poseID, startFrame: $0.startFrame)
        }
        XCTAssertEqual(
            KeepLayerGate.outcome(of: examples, width: 8),
            KeepLayerGate.outcome(of: examples.reversed(), width: 8))
    }

    // MARK: - What it learns from (§3, §4.3)

    func testAMatchCoversHalfTheShorterOfTheTwo() {
        XCTAssertTrue(KeepExample.matches((0, 10), (5, 30)))
        XCTAssertFalse(KeepExample.matches((0, 10), (6, 30)))
        XCTAssertTrue(KeepExample.matches((10, 20), (0, 40)))
        XCTAssertFalse(KeepExample.matches((0, 10), (10, 20)))
    }

    private func libraryClip(
        _ start: TimeInterval, _ end: TimeInterval, poseID: String?, recorded: TimeInterval = 1_000
    ) -> LibraryClip {
        LibraryClip(
            id: UUID(), sourceAssetID: "source", startTime: start, endTime: end, exportAssetID: "export", names: [],
            isMe: true, isAutoDetected: true, proposal: nil, poseID: poseID,
            recordedAt: Date(timeIntervalSince1970: recorded + start), savedAt: Date())
    }

    private func band(_ start: Int, _ end: Int, axis: Int = 0) -> BandSegment {
        BandSegment(startFrame: start, endFrame: end, score: 0.55, vector: PersonalFixture.axis(axis))
    }

    private func dismissed(_ start: Int, _ end: Int, poseID: String = "pose") -> DismissedWindow {
        DismissedWindow(sourceAssetID: "source", poseID: poseID, startFrame: start, endFrame: end)
    }

    /// A band segment over a saved clip is kept, which covers kept proposals and "+" clips alike;
    /// one over a trashed proposal is dismissed; one over neither has no label.
    func testABandSegmentIsLabeledByWhatTheUserDidThere() {
        let examples = KeepExample.examples(
            bandSegments: ["pose": [band(20, 30), band(60, 70), band(100, 110)]],
            clips: [libraryClip(2, 3, poseID: "pose")], dismissed: [dismissed(58, 72)])
            .sorted { $0.startFrame < $1.startFrame }
        XCTAssertEqual(examples.map(\.startFrame), [20, 60])
        XCTAssertEqual(examples.map(\.isKept), [true, false])
    }

    /// A "+" clip over a trashed tile says a trick is there.
    func testASegmentOverBothASavedClipAndATrashedProposalIsKept() {
        let examples = KeepExample.examples(
            bandSegments: ["pose": [band(20, 30)]], clips: [libraryClip(2, 3, poseID: "pose")],
            dismissed: [dismissed(20, 30)])
        XCTAssertEqual(examples.map(\.isKept), [true])
    }

    /// Following everyone, each person's segments are labeled by their own clips and trashed
    /// proposals only, and a pose no clip names any more contributes nothing.
    func testEachPosesSegmentsAreLabeledByItsOwnClipsAndProposals() {
        let examples = KeepExample.examples(
            bandSegments: [
                "athlete": [band(20, 30)], "bystander": [band(20, 30), band(60, 70)], "gone": [band(20, 30)]
            ],
            clips: [libraryClip(2, 3, poseID: "athlete"), libraryClip(6, 7, poseID: "bystander")],
            dismissed: [dismissed(20, 30, poseID: "bystander"), dismissed(20, 30, poseID: "gone")])
        let labels = Dictionary(examples.map { ("\($0.poseID)-\($0.startFrame)", $0.isKept) }) { first, _ in first }
        XCTAssertEqual(labels, ["athlete-20": true, "bystander-20": false, "bystander-60": true])
    }

    /// A segment happened at its source's recording date plus its offset, the clock the gate holds
    /// the newest out by.
    func testASegmentIsDatedByItsSourcePlusItsOffset() {
        let examples = KeepExample.examples(
            bandSegments: ["pose": [band(20, 30), band(60, 70)]],
            clips: [
                libraryClip(2, 3, poseID: "pose", recorded: 5_000), libraryClip(6, 7, poseID: "pose", recorded: 5_000)
            ],
            dismissed: [])
            .sorted { $0.startFrame < $1.startFrame }
        XCTAssertEqual(
            examples.map(\.recordedAt), [Date(timeIntervalSince1970: 5_002), Date(timeIntervalSince1970: 5_006)])
    }

    // MARK: - Band segments

    /// Only segments scoring inside `[0.3, 0.7)` are the layer's, each with its embedding by §4.1's
    /// rule over its own frames.
    func testARunsBandSegmentsAreTheOnesInsideTheBand() {
        let run = KeepFixture.run(scores: [0.29, 0.3, 0.55, 0.69, 0.7, 0.95], axes: [0, 1, 2, 3, 4, 5])
        let segments = run.bandSegments
        XCTAssertEqual(segments.map(\.startFrame), [20, 40, 60])
        XCTAssertEqual(segments.map(\.endFrame), [30, 50, 70])
        XCTAssertEqual(segments.map(\.score), [0.3, 0.55, 0.69])
        XCTAssertEqual(
            segments.map(\.vector), [PersonalFixture.axis(1), PersonalFixture.axis(2), PersonalFixture.axis(3)])
    }

    // MARK: - Step 1 (MODEL_CONTRACT.md §3.3)

    /// The layer decides the band and nothing else: a sure segment passes and a weak one never
    /// does, whatever it says.
    func testTheLayerDecidesTheBandOnly() {
        let rules = TrickProposalRules()
        let decoded = [
            segment(0, 10, 0.29), segment(20, 30, 0.3), segment(40, 50, 0.49), segment(60, 70, 0.5),
            segment(80, 90, 0.69), segment(100, 110, 0.7)
        ]
        XCTAssertEqual(rules.segments(from: decoded).map(\.startFrame), [60, 80, 100])
        XCTAssertEqual(rules.segments(from: decoded, keeping: { _ in true }).map(\.startFrame), [20, 40, 60, 80, 100])
        XCTAssertEqual(rules.segments(from: decoded, keeping: { _ in false }).map(\.startFrame), [100])
    }

    /// Where the layer can't decide a segment, the threshold does.
    func testASegmentTheLayerCantDecideFallsToTheThreshold() {
        let decoded = [segment(20, 30, 0.4), segment(60, 70, 0.6)]
        XCTAssertEqual(TrickProposalRules().segments(from: decoded, keeping: { _ in nil }).map(\.startFrame), [60])
    }

    /// NMS and merging run after the layer as written: a band segment it keeps is still suppressed
    /// by a surer one it overlaps.
    func testNMSAndMergingStillRunAfterTheLayer() {
        let decoded = [segment(0, 30, 0.9, ["cork"]), segment(5, 30, 0.4, ["gainer"])]
        XCTAssertEqual(
            TrickProposalRules().segments(from: decoded, keeping: { _ in true }).map(\.trickNames), [["cork"]])
    }

    /// A run decides with a layer fit under its own model version, reading each segment's
    /// embedding; a layer from another version decides nothing.
    func testARunDecidesWithALayerFitUnderItsOwnVersion() throws {
        let run = KeepFixture.run(scores: [0.4, 0.6], axes: [0, 1])
        let picky = layer(KeepLayerParameters(scale: 1, offset: 0, weights: [3, -3, 0, 0, 0, 0, 0, 0]))
        let keep = try XCTUnwrap(run.keepDecision(by: picky))
        XCTAssertEqual(keep(segment(0, 10, 0.4)), true)
        XCTAssertEqual(keep(segment(20, 30, 0.6)), false)

        XCTAssertNil(run.keepDecision(by: nil))
        XCTAssertNil(run.keepDecision(by: layer(picky.parameters, version: "v2")))
    }
}
