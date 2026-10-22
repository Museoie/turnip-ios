import XCTest
@testable import Turnip

final class EvaluationManifestTests: XCTestCase {
    /// The shape every `labels.json` has today: bare `[start, end]` pairs, keys the evaluation
    /// doesn't read, and a video nobody has labelled.
    func testDecodesTricksAsStartEndPairs() throws {
        let manifest = try decode("""
            {
              "about": "Hand-labelled trick windows.",
              "clips": [
                { "video": "a.MOV", "group": "tripod", "tricks": [[7.3, 10.5], [14.5, 17.0]], "notes": "Near." },
                { "video": "b.MOV", "group": "unlabelled", "tricks": null, "notes": "Not labelled." }
              ]
            }
            """)

        XCTAssertEqual(manifest.clips.map(\.video), ["a.MOV", "b.MOV"])
        XCTAssertEqual(manifest.clips[0].tricks, [
            LabelledTrick(window: 7.3...10.5),
            LabelledTrick(window: 14.5...17.0)
        ])
        XCTAssertNil(manifest.clips[1].tricks)
    }

    func testDecodesATrickThatSaysWhoDidIt() throws {
        let tricks = try decodeTricks("""
            [{ "window": [12.0, 13.6], "person": "teal shirt", "at": [0.25, 0.6] }]
            """)

        XCTAssertEqual(tricks, [
            LabelledTrick(window: 12.0...13.6, person: "teal shirt", position: LabelledTrick.Position(x: 0.25, y: 0.6))
        ])
    }

    /// A take can be labelled a trick at a time: pairs and objects in one list, and an object
    /// that names the person before anyone has placed them.
    func testDecodesPairsAndObjectsTogether() throws {
        let tricks = try decodeTricks("""
            [[1, 2], { "window": [3, 4] }, { "window": [5, 6], "person": "grey hoodie" }]
            """)

        XCTAssertEqual(tricks, [
            LabelledTrick(window: 1...2),
            LabelledTrick(window: 3...4),
            LabelledTrick(window: 5...6, person: "grey hoodie")
        ])
    }

    func testRejectsAWindowThatIsNotStartBeforeEnd() {
        for json in ["[[7.3]]", "[[7.3, 10.5, 12]]", "[[10.5, 7.3]]", "[[7.3, 7.3]]", #"[{ "window": [10.5, 7.3] }]"#] {
            XCTAssertThrowsError(try decodeTricks(json), json)
        }
    }

    /// `at` is a fraction of the frame, so pixel coordinates fail loudly rather than score
    /// every trick as the wrong person.
    func testRejectsAPositionThatIsNotAFractionOfTheFrame() {
        for json in [#"[{ "window": [1, 2], "at": [540, 960] }]"#, #"[{ "window": [1, 2], "at": [0.5] }]"#] {
            XCTAssertThrowsError(try decodeTricks(json), json)
        }
    }

    private func decode(_ json: String) throws -> EvaluationManifest {
        try JSONDecoder().decode(EvaluationManifest.self, from: Data(json.utf8))
    }

    private func decodeTricks(_ json: String) throws -> [LabelledTrick] {
        try JSONDecoder().decode([LabelledTrick].self, from: Data(json.utf8))
    }
}
