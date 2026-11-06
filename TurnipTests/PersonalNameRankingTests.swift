import XCTest
@testable import Turnip

/// Vectors for the personal layer's tests: one axis per direction, so which prototype is nearest is
/// plain to read.
enum PersonalFixture {
    static let vocabulary = TrickVocabulary(taxonomyVersion: 1, entries: [
        .init(canonical: "cork", aliases: ["cork", "corkscrew"]),
        .init(canonical: "gainer", aliases: ["gainer"]),
        .init(canonical: "hook", aliases: ["hook"]),
        .init(canonical: "scoot", aliases: ["scoot"])
    ])

    /// A unit vector along `axis`, leaning a little toward the next axis by `lean`.
    static func axis(_ axis: Int, lean: Float = 0, width: Int = 8) -> [Float] {
        var vector = [Float](repeating: 0, count: width)
        vector[axis] = 1
        vector[(axis + 1) % width] = lean
        return vector.unitLength ?? vector
    }

    static func example(
        _ names: [String: Float], vector: [Float], central: [String] = [], listed: Set<String> = [],
        at seconds: TimeInterval = 0, spellings: [String: String] = [:]
    ) -> PersonalExample {
        PersonalExample(
            id: UUID(), vector: vector, weights: names, spellings: spellings, centralKeys: central,
            listedKeys: listed, recordedAt: Date(timeIntervalSince1970: seconds))
    }

    static func clip(
        _ names: [ClipName], source: String = UUID().uuidString, at seconds: TimeInterval = 0, id: UUID = UUID(),
        proposal: ModelProposal? = nil, poseID: String? = nil
    ) -> LibraryClip {
        LibraryClip(
            id: id, sourceAssetID: source, startTime: 0, endTime: 1, exportAssetID: "export", names: names, isMe: true,
            isAutoDetected: true, proposal: proposal, poseID: poseID,
            recordedAt: Date(timeIntervalSince1970: seconds), savedAt: Date(timeIntervalSince1970: seconds))
    }

    static func typed(_ name: String) -> ClipName { ClipName(name: name, origin: .typed) }
}

/// `MODEL_CONTRACT.md` §3.5's clip embedding, on a grid where row `i` covers frames `[5i, 5i + 10)`.
final class ClipEmbeddingTests: XCTestCase {
    private let descriptor = TrickModelDescriptor(
        classes: ["background", "cork", "gainer", "cork+gainer", "hook"], windowFrames: 10, windowStride: 5)

    private func embeddings(rows: [[Float]], probabilities: [[Float]]? = nil) -> WindowEmbeddings {
        WindowEmbeddings(
            personID: nil, modelVersion: "v1", descriptor: descriptor, rows: rows,
            probabilities: probabilities ?? rows.map { _ in [1, 0, 0, 0, 0] })
    }

    /// Row `i` points along axis `i`, so an embedding says exactly which rows went into it.
    private var axisRows: [[Float]] { (0..<8).map { PersonalFixture.axis($0) } }

    private func window(_ start: Double, _ end: Double) -> TrickWindow {
        TrickWindow(startTime: start, endTime: end)
    }

    func testRowsWhollyInsideTheClipAreTheOnesItReads() {
        XCTAssertEqual(embeddings(rows: axisRows).rowIndices(for: window(0.5, 2)), [1, 2])
    }

    /// Frames 0..<15 hold rows 0 and 1 whole, and row 1 ends exactly where the clip does.
    func testARowEndingExactlyAtTheClipsEndIsInside() {
        XCTAssertEqual(embeddings(rows: axisRows).rowIndices(for: window(0, 1.5)), [0, 1])
    }

    /// The mean of two orthogonal unit rows, renormalized, sits halfway between them.
    func testTheEmbeddingIsTheMeanOfThoseRowsAtUnitLength() throws {
        let embedding = try XCTUnwrap(embeddings(rows: axisRows).clipEmbedding(of: window(0.5, 2)))
        XCTAssertEqual(embedding.vector[1], Float(0.5).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(embedding.vector[2], Float(0.5).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(embedding.vector.dot(embedding.vector), 1, accuracy: 1e-6)
        XCTAssertEqual(embedding.modelVersion, "v1")
    }

    /// A clip trimmed shorter than one window holds no row whole, so it takes the one it overlaps
    /// most: frames 7..<12 overlap row 0 by 3, row 1 by 5 and row 2 by 2.
    func testAClipShorterThanAWindowTakesTheMostOverlappingRow() {
        XCTAssertEqual(embeddings(rows: axisRows).rowIndices(for: window(0.7, 1.2)), [1])
    }

    /// Frames 5..<10 overlap rows 0 and 1 by the same 5 frames.
    func testEqualOverlapsTakeTheEarlierRow() {
        XCTAssertEqual(embeddings(rows: axisRows).rowIndices(for: window(0.5, 1)), [0])
    }

    func testAClipPastTheLastWindowTakesTheLastRow() {
        XCTAssertEqual(embeddings(rows: axisRows).rowIndices(for: window(30, 31)), [7])
    }

    func testAWindowIsReadInCanonicalFramesTheWayContributionReadsIt() {
        let rows = embeddings(rows: axisRows)
        let frames = ContributionPose.canonicalFrames(of: window(0.51, 1.49), frameCount: 45)
        XCTAssertEqual(frames.start, 5)
        XCTAssertEqual(frames.end, 15)
        XCTAssertEqual(rows.rowIndices(for: window(0.51, 1.49)), [1])
    }

    func testNoRowsHasNoEmbedding() {
        XCTAssertNil(embeddings(rows: []).clipEmbedding(of: window(0, 1)))
    }

    func testAllZeroRowsHaveNoDirectionToKeep() {
        XCTAssertNil(embeddings(rows: [[0, 0], [0, 0]]).clipEmbedding(of: window(0, 1)))
    }

    // MARK: - The central model's names for a clip

    func testCentralNamesComeSurestFirstWithoutTheBackground() throws {
        let probabilities: [[Float]] = [[0.5, 0.1, 0.3, 0, 0.1]]
        let embedding = embeddings(rows: [[1, 0]], probabilities: probabilities).clipEmbedding(of: window(0, 1))
        XCTAssertEqual(embedding?.centralNames, ["gainer", "cork", "hook"])
    }

    /// `cork+gainer` is a class of its own: each of its names takes its score when that beats the
    /// name's own class.
    func testACombosClassScoresBothItsNames() {
        let probabilities: [[Float]] = [[0.1, 0.1, 0, 0.7, 0.1]]
        let embedding = embeddings(rows: [[1, 0]], probabilities: probabilities).clipEmbedding(of: window(0, 1))
        XCTAssertEqual(embedding?.centralNames, ["cork", "gainer", "hook"])
    }

    /// The same rows the embedding reads, averaged: hook only wins row 0, which this clip leaves out.
    func testCentralNamesReadTheClipsOwnRows() {
        let rows = (0..<3).map { PersonalFixture.axis($0) }
        let probabilities: [[Float]] = [[0, 0, 0, 0, 1], [0, 1, 0, 0, 0], [0, 0.6, 0.4, 0, 0]]
        let embedding = embeddings(rows: rows, probabilities: probabilities).clipEmbedding(of: window(0.5, 2))
        XCTAssertEqual(embedding?.centralNames.first, "cork")
        XCTAssertEqual(embedding?.centralNames.last, "hook")
    }

    /// Every clip gets three to compare, so the gate's central side isn't short of what §5 cuts it at.
    func testAClipGetsEveryNameTheModelCanOffer() {
        let embedding = embeddings(rows: [[1, 0]]).clipEmbedding(of: window(0, 1))
        XCTAssertEqual(embedding.map { Set($0.centralNames) }, ["cork", "gainer", "hook"])
    }
}

final class NamePrototypesTests: XCTestCase {
    private let vocabulary = PersonalFixture.vocabulary

    private func prototypes(_ examples: [PersonalExample]) -> [String: NamePrototype] {
        Dictionary(uniqueKeysWithValues: NamePrototypes(examples).all().map { ($0.key, $0) })
    }

    func testANameNeedsThreeClips() {
        let two = (0..<2).map { _ in PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(0)) }
        XCTAssertTrue(NamePrototypes(two).all().isEmpty)
        let three = two + [PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(0))]
        XCTAssertEqual(NamePrototypes(three).all().map(\.key), ["cork"])
    }

    /// A kept pre-fill counts half: two clips along one axis and one along another give 2 : 0.5.
    func testAPrototypeWeighsItsClipsByOrigin() throws {
        let prototype = try XCTUnwrap(prototypes([
            PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(0)),
            PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(0)),
            PersonalFixture.example(["cork": 0.5], vector: PersonalFixture.axis(1))
        ])["cork"])
        XCTAssertEqual(prototype.vector[0] / prototype.vector[1], 4, accuracy: 1e-5)
        XCTAssertEqual(prototype.vector.dot(prototype.vector), 1, accuracy: 1e-5)
    }

    func testOriginWeights() {
        XCTAssertEqual(PersonalExample.weight(of: .typed), 1)
        XCTAssertEqual(PersonalExample.weight(of: .vocabulary), 1)
        XCTAssertEqual(PersonalExample.weight(of: .model), 0.5)
    }

    private func examples(_ clips: [LibraryClip], vector: [Float] = PersonalFixture.axis(0)) -> [PersonalExample] {
        let embedding = ClipEmbedding(modelVersion: "v1", vector: vector, centralNames: [])
        let embeddings = Dictionary(uniqueKeysWithValues: clips.map { ($0.id.uuidString, embedding) })
        return PersonalExample.examples(from: clips, embeddings: embeddings, vocabulary: vocabulary)
    }

    /// A combo adds its embedding to each of its names.
    func testAComboCountsTowardEachOfItsNames() {
        let clips = (0..<3).map { _ in
            PersonalFixture.clip([PersonalFixture.typed("cork"), PersonalFixture.typed("hook")])
        }
        XCTAssertEqual(Set(NamePrototypes(examples(clips)).all().map(\.key)), ["cork", "hook"])
    }

    /// `cork-hook` written as one name resolves the way grouping resolves it.
    func testAComboWrittenAsOneNameCountsTowardEachPart() {
        let clips = (0..<3).map { _ in PersonalFixture.clip([PersonalFixture.typed("cork-hook")]) }
        XCTAssertEqual(Set(NamePrototypes(examples(clips)).all().map(\.key)), ["cork", "hook"])
    }

    /// An alias and its canonical name on one clip are one key: it counts once, at the higher weight.
    func testTwoNamesWithOneKeyCountOnceAtTheHigherWeight() throws {
        let clip = PersonalFixture.clip([
            ClipName(name: "corkscrew", origin: .model), ClipName(name: "cork", origin: .vocabulary)
        ])
        let example = try XCTUnwrap(examples([clip]).first)
        XCTAssertEqual(example.weights, ["cork": 1])
        XCTAssertTrue(NamePrototypes([example, example]).all().isEmpty, "two clips, not four")
    }

    func testAMappedNameShowsAsTheCanonicalName() {
        let clips = (0..<3).map { _ in PersonalFixture.clip([PersonalFixture.typed("Corkscrew")]) }
        XCTAssertEqual(NamePrototypes(examples(clips)).all().map(\.name), ["cork"])
    }

    /// A name the vocabulary doesn't map keeps the user's own spelling, the latest they used.
    func testAnUnmappedNameShowsAsTheMostRecentSpelling() {
        let clips = [
            PersonalFixture.clip([PersonalFixture.typed("Flash Kick")], at: 10),
            PersonalFixture.clip([PersonalFixture.typed("flash KICK")], at: 30),
            PersonalFixture.clip([PersonalFixture.typed("flash kick")], at: 20)
        ]
        let all = NamePrototypes(examples(clips)).all()
        XCTAssertEqual(all.map(\.key), ["flash kick"])
        XCTAssertEqual(all.map(\.name), ["flash KICK"])
    }

    func testOnlyNamedClipsWithAnEmbeddingAreExamples() {
        let named = PersonalFixture.clip([PersonalFixture.typed("cork")])
        let unnamed = PersonalFixture.clip([])
        let unembedded = PersonalFixture.clip([PersonalFixture.typed("cork")])
        let embedding = ClipEmbedding(modelVersion: "v1", vector: PersonalFixture.axis(0), centralNames: [])
        let examples = PersonalExample.examples(
            from: [named, unnamed, unembedded],
            embeddings: [named.id.uuidString: embedding, unnamed.id.uuidString: embedding], vocabulary: vocabulary)
        XCTAssertEqual(examples.map(\.id), [named.id])
    }

    /// What tier 1 lists for a clip is what its video's other clips are named, embedded or not.
    func testListedKeysAreTheVideosOtherClipsNames() throws {
        let clip = PersonalFixture.clip([PersonalFixture.typed("cork")], source: "video")
        let sibling = PersonalFixture.clip([PersonalFixture.typed("hook")], source: "video")
        let elsewhere = PersonalFixture.clip([PersonalFixture.typed("scoot")], source: "other")
        let embedding = ClipEmbedding(modelVersion: "v1", vector: PersonalFixture.axis(0), centralNames: [])
        let examples = PersonalExample.examples(
            from: [clip, sibling, elsewhere], embeddings: [clip.id.uuidString: embedding], vocabulary: vocabulary)
        XCTAssertEqual(try XCTUnwrap(examples.first).listedKeys, ["hook"])
    }

    func testCentralNamesBecomeKeysInTheirOrderEachOnce() throws {
        let clip = PersonalFixture.clip([PersonalFixture.typed("cork")])
        let embedding = ClipEmbedding(
            modelVersion: "v1", vector: PersonalFixture.axis(0), centralNames: ["hook", "corkscrew", "cork"])
        let examples = PersonalExample.examples(
            from: [clip], embeddings: [clip.id.uuidString: embedding], vocabulary: vocabulary)
        XCTAssertEqual(try XCTUnwrap(examples.first).centralKeys, ["hook", "cork"])
    }

    /// Leaving a clip out by subtraction gives what building without it gives.
    func testLeavingAClipOutMatchesNeverHavingIt() throws {
        let kept = (0..<3).map {
            PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(0, lean: Float($0) / 5))
        }
        let left = PersonalFixture.example(["cork": 0.5], vector: PersonalFixture.axis(3))
        let subtracted = try XCTUnwrap(NamePrototypes(kept + [left]).all(leavingOut: left).first)
        let without = try XCTUnwrap(NamePrototypes(kept).all().first)
        for (lhs, rhs) in zip(subtracted.vector, without.vector) {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-5)
        }
    }

    func testLeavingOutAThirdClipTakesTheNameBelowTheMinimum() {
        let examples = (0..<3).map { _ in PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(0)) }
        XCTAssertTrue(NamePrototypes(examples).all(leavingOut: examples[0]).isEmpty)
    }
}

/// The tiers of `docs/PERSONALIZATION_DESIGN.md` §4.2.
final class PersonalSuggestionsTests: XCTestCase {
    private let vocabulary = PersonalFixture.vocabulary

    private func prototype(_ key: String, axis: Int, name: String? = nil) -> NamePrototype {
        NamePrototype(key: key, name: name ?? key, vector: PersonalFixture.axis(axis))
    }

    private var ranking: PersonalNameRanking {
        PersonalNameRanking(
            modelVersion: "v1",
            prototypes: [
                prototype("cork", axis: 0), prototype("gainer", axis: 1), prototype("hook", axis: 2),
                prototype("scoot", axis: 3), prototype("flash kick", axis: 4, name: "Flash Kick")
            ],
            vocabulary: vocabulary)
    }

    /// Near axis 2, with axis 1 next and axis 0 after it.
    private let target = [Float]([0.1, 0.3, 0.9, 0, 0, 0, 0, 0]).unitLength ?? []

    func testUsedNamesOrderByCloseness() {
        let suggestions = ranking.suggestions(for: target, used: ["cork", "gainer", "hook"], given: [])
        XCTAssertEqual(suggestions.used, ["hook", "gainer", "cork"])
    }

    func testAUsedNameWithNoPrototypeFollowsTheOnesThatHaveOne() {
        let suggestions = ranking.suggestions(for: target, used: ["spin", "cork", "twist", "hook"], given: [])
        XCTAssertEqual(suggestions.used, ["hook", "cork", "spin", "twist"])
    }

    func testTheNearestThreeFollowNotAlreadyListed() {
        let suggestions = ranking.suggestions(for: target, used: ["hook"], given: [])
        XCTAssertEqual(suggestions.nearest.count, 3)
        XCTAssertEqual(Array(suggestions.nearest.prefix(2)), ["gainer", "cork"])
        XCTAssertFalse(suggestions.nearest.contains("hook"))
    }

    func testANameTheClipAlreadyHasIsntSuggested() {
        let suggestions = ranking.suggestions(for: target, used: [], given: [PersonalFixture.typed("Hook")])
        XCTAssertFalse(suggestions.nearest.contains("hook"))
        XCTAssertEqual(suggestions.nearest.first, "gainer")
    }

    /// `corkscrew` is listed, so its canonical name isn't offered as if it were a different name.
    func testAnAliasListsItsCanonicalName() {
        let suggestions = ranking.suggestions(for: PersonalFixture.axis(0), used: ["corkscrew"], given: [])
        XCTAssertFalse(suggestions.nearest.contains("cork"))
    }

    func testAnUnmappedNameShowsAsTheUserSpellsIt() {
        let suggestions = ranking.suggestions(for: PersonalFixture.axis(4), used: [], given: [])
        XCTAssertEqual(suggestions.nearest.first, "Flash Kick")
    }

    // MARK: - On screen

    private func ordered(
        draft: String = "", given: [ClipName] = [], used: [String] = [], nearest: [String] = []
    ) -> [String] {
        NamingSuggestions.ordered(
            draft: draft, given: given, suggested: PersonalSuggestions(used: used, nearest: nearest),
            vocabulary: vocabulary)
    }

    func testTheVideosNamesLeadThenTheNearestThenTheVocabulary() {
        XCTAssertEqual(
            ordered(used: ["hook"], nearest: ["Flash Kick", "scoot"]),
            ["hook", "Flash Kick", "scoot", "cork", "gainer"])
    }

    func testWithNoPersonalNamesTheOrderIsTheVideosThenTheVocabulary() {
        XCTAssertEqual(ordered(used: ["scoot"]), ["scoot", "cork", "gainer", "hook"])
    }

    func testPersonalNamesFollowTheDraftLikeTheVideosNames() {
        XCTAssertEqual(ordered(draft: "fla", used: ["hook"], nearest: ["Flash Kick"]), ["Flash Kick"])
    }

    func testANameIsSuggestedOnceHoweverManyTiersHaveIt() {
        XCTAssertEqual(ordered(used: ["hook"], nearest: ["Hook", "gainer"]), ["hook", "gainer", "cork", "scoot"])
    }

    func testANameTheClipHasIsLeftOut() {
        XCTAssertEqual(
            ordered(given: [PersonalFixture.typed("HOOK")], used: ["hook"], nearest: ["gainer"]),
            ["gainer", "cork", "scoot"])
    }

    func testAtMostEightShow() {
        let used = (0..<6).map { "trick \($0)" }
        XCTAssertEqual(ordered(used: used, nearest: ["a", "b", "c"]).count, 8)
    }

    /// Picking from tier 2 is any other pick: the farm can't tell it from one.
    func testOriginIsWhatItIsForAnyOtherPick() {
        XCTAssertEqual(NamingSuggestions.origin(of: "gainer", vocabulary: vocabulary), .vocabulary)
        XCTAssertEqual(NamingSuggestions.origin(of: "corkscrew", vocabulary: vocabulary), .vocabulary)
        XCTAssertEqual(NamingSuggestions.origin(of: "Flash Kick", vocabulary: vocabulary), .typed)
    }
}

/// `docs/PERSONALIZATION_DESIGN.md` §5. Ten clips of `flash kick` along one axis: the name the central
/// model can't say.
final class NameRankingGateTests: XCTestCase {
    private func flashKicks(_ count: Int, central: [String] = ["cork"]) -> [PersonalExample] {
        (0..<count).map {
            PersonalFixture.example(
                ["flash kick": 1], vector: PersonalFixture.axis(0), central: central, at: TimeInterval($0))
        }
    }

    func testTooFewClipsSayNothing() {
        XCTAssertNil(NameRankingGate.outcome(of: flashKicks(9)))
        XCTAssertNotNil(NameRankingGate.outcome(of: flashKicks(10)))
    }

    /// A name outside the vocabulary can never be a central hit, so ranking wins every clip.
    func testRankingPassesWhenItBeatsTheCentralModel() throws {
        let outcome = try XCTUnwrap(NameRankingGate.outcome(of: flashKicks(10)))
        XCTAssertEqual(outcome, .init(clips: 10, personalHits: 10, centralHits: 0))
        XCTAssertTrue(outcome.passes)
    }

    func testRankingFailsWhenTheCentralModelBeatsIt() throws {
        let corks = (0..<10).map { index in
            PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(index % 8), central: ["cork"])
        }
        let outcome = try XCTUnwrap(NameRankingGate.outcome(of: corks))
        XCTAssertEqual(outcome.centralHits, 10)
        XCTAssertFalse(outcome.passes)
    }

    func testATieLeavesRankingOff() throws {
        let outcome = try XCTUnwrap(NameRankingGate.outcome(of: flashKicks(10, central: ["flash kick"])))
        XCTAssertEqual(outcome.personalHits, outcome.centralHits)
        XCTAssertFalse(outcome.passes)
    }

    /// Three clips of a name, ten clips in all: held out, each leaves its name two clips and no
    /// prototype, so a clip can't be a hit on its own evidence.
    func testAHeldOutClipIsNotInItsOwnPrototype() throws {
        let rare = (0..<3).map { PersonalFixture.example(["rare": 1], vector: PersonalFixture.axis($0)) }
        let others = (0..<7).map { PersonalFixture.example(["other \($0)": 1], vector: PersonalFixture.axis(7)) }
        let outcome = try XCTUnwrap(NameRankingGate.outcome(of: rare + others))
        XCTAssertEqual(outcome.personalHits, 0)
    }

    func testOnlyTheNewestFiftyClipsAreHeldOut() throws {
        let old = (0..<60).map { _ in PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(0), at: 0) }
        let new = (0..<50).map {
            PersonalFixture.example(["hook": 1], vector: PersonalFixture.axis(1), at: 100 + Double($0))
        }
        let outcome = try XCTUnwrap(NameRankingGate.outcome(of: old + new))
        XCTAssertEqual(outcome.clips, 50)
        XCTAssertEqual(outcome.personalHits, 50)
    }

    /// Every clip counts toward the prototypes, not just the fifty held out: only the two older
    /// hooks keep a held-out hook's name above the three clips a prototype needs.
    func testClipsOlderThanTheFiftyStillShapeThePrototypes() throws {
        let old = (0..<2).map { _ in PersonalFixture.example(["hook": 1], vector: PersonalFixture.axis(1), at: 0) }
        let corks = (0..<48).map { index in
            PersonalFixture.example(["cork": 1], vector: PersonalFixture.axis(0), at: 100 + Double(index))
        }
        let hooks = (0..<2).map { index in
            PersonalFixture.example(["hook": 1], vector: PersonalFixture.axis(1), at: 200 + Double(index))
        }
        let outcome = try XCTUnwrap(NameRankingGate.outcome(of: old + corks + hooks))
        XCTAssertEqual(outcome.clips, 50)
        XCTAssertEqual(outcome.personalHits, 50)
    }

    /// The central model's fourth name doesn't count, however right it is.
    func testTheCentralSideIsCutAtThreeNames() throws {
        let clips = flashKicks(10, central: ["a", "b", "c", "flash kick"])
        XCTAssertEqual(try XCTUnwrap(NameRankingGate.outcome(of: clips)).centralHits, 0)
    }

    /// Four names closer than the clip's own leave it fourth, so tier 2 doesn't reach it.
    func testThePersonalSideIsCutAtThreeNames() throws {
        var clips: [PersonalExample] = []
        for (index, key) in ["a", "b", "c"].enumerated() {
            clips += (0..<3).map { _ in
                PersonalFixture.example([key: 1], vector: PersonalFixture.axis(0, lean: Float(index) * 0.01), at: 0)
            }
        }
        let far = (0..<4).map { index in
            PersonalFixture.example(["far": 1], vector: PersonalFixture.axis(4), at: 10 + Double(index))
        }
        let held = PersonalFixture.example(["far": 1], vector: PersonalFixture.axis(0), at: 100)
        let outcome = try XCTUnwrap(NameRankingGate.outcome(of: clips + far + [held]))
        let withoutHeld = try XCTUnwrap(NameRankingGate.outcome(of: clips + far))
        XCTAssertEqual(outcome.personalHits, withoutHeld.personalHits, "the held clip's name is fourth, so it's no hit")
    }

    /// A combo clip with both names among the three is one hit, not two.
    func testAClipCountsOnceHoweverManyOfItsNamesHit() throws {
        let combos = (0..<10).map { index in
            PersonalFixture.example(["a": 1, "b": 1], vector: PersonalFixture.axis(0), at: Double(index))
        }
        XCTAssertEqual(try XCTUnwrap(NameRankingGate.outcome(of: combos)).personalHits, 10)
    }

    /// A name already on the video's other clips is in tier 1 either way, so finding it again is no
    /// credit to either side.
    func testNamesTier1ListsScoreForNeitherSide() throws {
        let session = (0..<10).map { index in
            PersonalFixture.example(
                ["cork": 1], vector: PersonalFixture.axis(0), central: ["cork"], listed: ["cork"], at: Double(index))
        }
        let outcome = try XCTUnwrap(NameRankingGate.outcome(of: session))
        XCTAssertEqual(outcome.personalHits, 0)
        XCTAssertEqual(outcome.centralHits, 0)
    }

    /// With a listed name out of the way, the next name moves up to third on each side.
    func testBothSidesFillTheirThreeAfterListedNamesComeOut() throws {
        let clips = (0..<10).map { index in
            PersonalFixture.example(
                ["hit": 1], vector: PersonalFixture.axis(0), central: ["listed", "a", "b", "hit"], listed: ["listed"],
                at: Double(index))
        }
        XCTAssertEqual(try XCTUnwrap(NameRankingGate.outcome(of: clips)).centralHits, 10)
    }
}
