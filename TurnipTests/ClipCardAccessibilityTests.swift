import XCTest
@testable import Turnip

/// The card's VoiceOver label is the accessibility contract for the triage list — a
/// wording regression here is silent (nothing crashes, VoiceOver just announces the
/// wrong thing), so the label builder gets the same assertion treatment as any other
/// behavior. The spoken duration pins against the formatter's English rendering; the
/// card label only checks that the formatter's output flows through untouched.
final class ClipCardAccessibilityTests: XCTestCase {
    func testLabelKept() {
        XCTAssertEqual(
            ClipCardView.accessibilityLabel(
                index: 1, spokenDuration: "2.4 seconds", isKept: true),
            "Clip 1, 2.4 seconds, kept"
        )
    }

    func testLabelDiscarded() {
        XCTAssertEqual(
            ClipCardView.accessibilityLabel(
                index: 2, spokenDuration: "3 seconds", isKept: false),
            "Clip 2, 3 seconds, discarded"
        )
    }

    func testLabelKeepsSingularSecond() {
        XCTAssertEqual(
            ClipCardView.accessibilityLabel(
                index: 3, spokenDuration: "1 second", isKept: true),
            "Clip 3, 1 second, kept"
        )
    }

    func testSpokenDurationTenths() {
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 2.4), "2.4 seconds")
    }

    func testSpokenDurationWholeSeconds() {
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 3.0), "3 seconds")
    }

    func testSpokenDurationSingularSecond() {
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 1.0), "1 second")
    }

    func testSpokenDurationNegativeFloorsToZero() {
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: -1), "0.0 seconds")
    }

    func testSpokenDurationNaNFloorsToZero() {
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: .nan), "0.0 seconds")
    }
}
