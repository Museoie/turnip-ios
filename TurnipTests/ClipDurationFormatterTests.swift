import XCTest
@testable import Turnip

final class ClipDurationFormatterTests: XCTestCase {
    func testWholeSecondsKeepTheTrailingZero() {
        // The whole-seconds decision, made once: "3.0s", not "3s", on every screen.
        XCTAssertEqual(ClipDurationFormatter.string(from: 3), "3.0s")
        XCTAssertEqual(ClipDurationFormatter.string(from: 0), "0.0s")
    }

    func testFractionalSecondsRoundToOneDecimalPlace() {
        XCTAssertEqual(ClipDurationFormatter.string(from: 2.4), "2.4s")
        XCTAssertEqual(ClipDurationFormatter.string(from: 2.37), "2.4s")
        XCTAssertEqual(ClipDurationFormatter.string(from: 2.34), "2.3s")
    }

    func testHalfTenthsRoundAwayFromZero() {
        // (1.15 * 10) is exactly 11.5 in binary floating point, and Swift's
        // .rounded() takes halves away from zero — pinning the rule the
        // implementation inherits from the original integer-math version.
        XCTAssertEqual(ClipDurationFormatter.string(from: 1.15), "1.2s")
        XCTAssertEqual(ClipDurationFormatter.string(from: 29.95), "30.0s")
    }

    func testDegenerateInputsRenderAsZero() {
        // Mirrors VideoDurationFormatter's floor: never a "-2.-4s" or "nans".
        XCTAssertEqual(ClipDurationFormatter.string(from: -2), "0.0s")
        XCTAssertEqual(ClipDurationFormatter.string(from: .nan), "0.0s")
        XCTAssertEqual(ClipDurationFormatter.string(from: .infinity), "0.0s")
    }

    func testDecimalSeparatorNeverFollowsTheLocale() {
        // Hand-built from integers, never a NumberFormatter: a German-locale device
        // must not print "2,4s".
        let label = ClipDurationFormatter.string(from: 2.4)
        XCTAssertTrue(label.contains("."))
        XCTAssertFalse(label.contains(","))
    }

    func testTriageCardReadsTheSameAsTheFormatter() {
        // One window, read through the card's label.
        let window = TrickWindow(startTime: 2, endTime: 5)
        let item = ClipListItem(
            window: window, cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
        XCTAssertEqual(item.durationLabel, "3.0s")
        XCTAssertEqual(item.durationLabel, ClipDurationFormatter.string(from: 3))
    }
}

/// "2.4s" reads as "two point four s" through a screen reader, so the card label and the trim
/// handles take a spoken form instead. Built from the same integer tenths as the badge, so a
/// window can never read as two different lengths on the same screen.
final class ClipDurationSpokenFormTests: XCTestCase {
    func testSpeaksTenthsOfASecond() {
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 2.4), "2.4 seconds")
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 0.7), "0.7 seconds")
    }

    /// A whole second drops the decimal the badge keeps ("3.0s"): "three point zero seconds"
    /// is the badge's own problem restated.
    func testWholeSecondsDropTheDecimal() {
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 3), "3 seconds")
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 1), "1 second")
    }

    func testDegenerateInputsFloorAtZero() {
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 0), "0 seconds")
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: -4), "0 seconds")
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: .nan), "0 seconds")
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: .infinity), "0 seconds")
    }

    /// Both forms round the same way off the same tenths, so the badge and the spoken label
    /// cannot disagree about which tenth a window lands on.
    func testRoundsTheSameWayAsTheBadge() {
        XCTAssertEqual(ClipDurationFormatter.string(from: 2.46), "2.5s")
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 2.46), "2.5 seconds")
        XCTAssertEqual(ClipDurationFormatter.string(from: 2.96), "3.0s")
        XCTAssertEqual(ClipDurationFormatter.accessibilityString(from: 2.96), "3 seconds")
    }
}
