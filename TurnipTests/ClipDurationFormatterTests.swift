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
        // Issue #90's verification: one window, read through the card's label.
        let window = TrickWindow(startTime: 2, endTime: 5)
        let item = ClipListItem(
            window: window, cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
        XCTAssertEqual(item.durationLabel, "3.0s")
        XCTAssertEqual(item.durationLabel, ClipDurationFormatter.string(from: 3))
    }
}
