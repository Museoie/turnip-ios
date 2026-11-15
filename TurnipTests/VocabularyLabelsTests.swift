import XCTest
@testable import Turnip

/// `SourceContribution.splitByVocabulary` and `LabelCandidates.batch` pin
/// (`BACKEND_DESIGN.md` §1.2.25, `docs/CONTRIBUTION_DESIGN.md` §4): only vocabulary names are
/// contributed, a clip left with none isn't, and the rest are suggested within the farm's limits.
final class VocabularyLabelsTests: XCTestCase {
    private static let videoID = String(repeating: "ab", count: 32)

    private static func clip(_ names: [ClipName]) -> ClipContribution {
        ClipContribution(
            clipID: UUID(), window: TrickWindow(startTime: 1, endTime: 2), autoDetected: true, names: names)
    }

    private static func source(_ clips: [ClipContribution]) -> SourceContribution {
        SourceContribution(
            videoID: videoID,
            pose: ContributionPose(
                sampleRate: 10, slots: Array(repeating: Array(repeating: 0.5, count: 51), count: 30)),
            clips: clips)
    }

    func testOnlyVocabularyNamesStayAndEachNewNameIsListedOnce() throws {
        let first = Self.clip([ClipName(name: "Corkscrew", origin: .typed), ClipName(name: "raiz", origin: .typed)])
        let second = Self.clip([ClipName(name: "RAIZ", origin: .typed), ClipName(name: "b twist", origin: .typed)])
        let third = Self.clip([ClipName(name: "hook", origin: .vocabulary)])

        let split = Self.source([first, second, third]).splitByVocabulary(.seed)

        XCTAssertEqual(split.unknown, ["raiz", "b twist"])
        let known = try XCTUnwrap(split.known)
        XCTAssertEqual(known.clips.map(\.clipID), [first.clipID, third.clipID], "the second clip has no known name")
        XCTAssertEqual(known.clips.map { $0.names.map(\.name) }, [["Corkscrew"], ["hook"]])
        XCTAssertEqual(known.videoID, Self.videoID)
    }

    func testNoClipWithAKnownNameLeavesNothingToContribute() {
        let split = Self.source([Self.clip([ClipName(name: "raiz", origin: .typed)])]).splitByVocabulary(.seed)
        XCTAssertNil(split.known)
        XCTAssertEqual(split.unknown, ["raiz"])
    }

    func testAllKnownNamesSuggestNothing() {
        let source = Self.source([Self.clip([ClipName(name: "cork", origin: .model)])])
        let split = source.splitByVocabulary(.seed)
        XCTAssertEqual(split.known, source)
        XCTAssertEqual(split.unknown, [])
    }

    func testDroppingNamesIgnoresCaseAndSpacing() throws {
        let source = Self.source([
            Self.clip([ClipName(name: "cork", origin: .typed), ClipName(name: "Hook", origin: .typed)])
        ])
        let dropped = try XCTUnwrap(source.droppingNames(["  hook "]))
        XCTAssertEqual(dropped.clips.first?.names.map(\.name), ["cork"])
        XCTAssertNil(source.droppingNames(["cork", "HOOK"]))
    }

    /// The farm's rule, pinned (`BACKEND_DESIGN.md` §1.2.25): a name is known when its trimmed,
    /// whitespace-collapsed, lowercased form equals that of any spelling or canonical name.
    func testANameIsKnownByItsNormalizedForm() {
        let vocabulary = TrickVocabulary(taxonomyVersion: 4, entries: [
            .init(canonical: "butterfly twist", aliases: []),
            .init(canonical: "cork", aliases: ["corkscrew"])
        ])
        XCTAssertTrue(vocabulary.knows("butterfly twist"), "a canonical name with no spelling of its own")
        XCTAssertTrue(vocabulary.knows("  Butterfly   TWIST "), "case, a double space and padding")
        XCTAssertTrue(vocabulary.knows("butterfly\ttwist"), "any run of whitespace")
        XCTAssertTrue(vocabulary.knows("CorkScrew"))
        XCTAssertTrue(vocabulary.knows("cork"))
        XCTAssertFalse(vocabulary.knows("butterfly-twist"))
        XCTAssertFalse(vocabulary.knows("corks"), "a near miss is a suggestion, not a match")
        XCTAssertFalse(vocabulary.knows(""))
        XCTAssertTrue(vocabulary.knows("butterfly\r\ntwist"), "a CR LF pair")
        XCTAssertTrue(vocabulary.knows("butterfly\u{0B}\u{0C}twist"), "vertical tab and form feed")
    }

    /// The farm's whitespace is ASCII only: a no-break space is an ordinary character, so a name
    /// spelled with one isn't the name spelled with a space.
    func testANoBreakSpaceIsNotWhitespace() {
        let vocabulary = TrickVocabulary(
            taxonomyVersion: 4, entries: [.init(canonical: "butterfly twist", aliases: [])])
        XCTAssertFalse(vocabulary.knows("butterfly\u{00A0}twist"))
        XCTAssertFalse(vocabulary.knows("\u{00A0}butterfly twist"), "nor is it trimmed")
        XCTAssertEqual(TrickVocabulary.farmNormalized("A\u{00A0}B"), "a\u{00A0}b")
        XCTAssertEqual(TrickVocabulary.farmNormalized(" \tA \n B\r "), "a b")
        XCTAssertEqual(TrickVocabulary.farmTrimmed("\u{00A0}raiz "), "\u{00A0}raiz")
        XCTAssertEqual(LabelCandidates.batch([" raiz\u{00A0}"]), ["raiz\u{00A0}"])
    }

    func testANameCountCountsEveryNameOnEveryClip() {
        let source = Self.source([
            Self.clip([ClipName(name: "cork", origin: .typed), ClipName(name: "hook", origin: .typed)]),
            Self.clip([ClipName(name: "cork", origin: .typed)])
        ])
        XCTAssertEqual(source.nameCount, 3)
    }

    /// The farm counts a name's length in UTF-16 code units, so an emoji counts two.
    func testCandidateLengthCountsUTF16() {
        let fits = String(repeating: "🤸", count: LabelCandidates.maximumLength / 2)
        let over = fits + "a"
        XCTAssertEqual(LabelCandidates.batch([fits, over]), [fits])
    }

    func testCandidateBatchesStayWithinTheFarmsLimits() {
        let long = String(repeating: "x", count: LabelCandidates.maximumLength + 1)
        let edge = String(repeating: "y", count: LabelCandidates.maximumLength)
        XCTAssertEqual(LabelCandidates.batch([" raiz ", "", "   ", "RAIZ", long, edge]), ["raiz", edge])

        let many = (0..<30).map { "name \($0)" }
        XCTAssertEqual(LabelCandidates.batch(many), Array(many.prefix(LabelCandidates.maximumCount)))
    }
}
