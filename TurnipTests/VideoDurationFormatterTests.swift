import XCTest
@testable import Turnip

final class VideoDurationFormatterTests: XCTestCase {
    func testMinutesAndSecondsWithoutHours() {
        XCTAssertEqual(VideoDurationFormatter.string(from: 0), "0:00")
        XCTAssertEqual(VideoDurationFormatter.string(from: 7), "0:07")
        XCTAssertEqual(VideoDurationFormatter.string(from: 65), "1:05")
        XCTAssertEqual(VideoDurationFormatter.string(from: 3599), "59:59")
    }

    func testHoursOnlyWhenNeeded() {
        XCTAssertEqual(VideoDurationFormatter.string(from: 3600), "1:00:00")
        XCTAssertEqual(VideoDurationFormatter.string(from: 3723), "1:02:03")
    }

    func testRoundsToNearestSecond() {
        XCTAssertEqual(VideoDurationFormatter.string(from: 7.4), "0:07")
        XCTAssertEqual(VideoDurationFormatter.string(from: 7.6), "0:08")
        // Rounding must carry into the minutes field, not print "0:60".
        XCTAssertEqual(VideoDurationFormatter.string(from: 59.7), "1:00")
    }

    func testDegenerateInputsFormatAsZero() {
        XCTAssertEqual(VideoDurationFormatter.string(from: -5), "0:00")
        XCTAssertEqual(VideoDurationFormatter.string(from: .nan), "0:00")
        XCTAssertEqual(VideoDurationFormatter.string(from: .infinity), "0:00")
    }

    // MARK: - accessibilityString

    func testSpokenSeconds() {
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 0), "0 seconds")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 1), "1 second")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 7), "7 seconds")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 59), "59 seconds")
    }

    func testSpokenMinutesAndHours() {
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 60), "1 minute")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 61), "1 minute, 1 second")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 65), "1 minute, 5 seconds")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 3600), "1 hour")
        XCTAssertEqual(
            VideoDurationFormatter.accessibilityString(from: 3723),
            "1 hour, 2 minutes, 3 seconds"
        )
        XCTAssertEqual(
            VideoDurationFormatter.accessibilityString(from: 3661),
            "1 hour, 1 minute, 1 second"
        )
    }

    func testSpokenZeroUnitsAreOmitted() {
        // Only nonzero units are named — "1 hour", not "1 hour, 0 minutes, 0 seconds".
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 120), "2 minutes")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 7200), "2 hours")
    }

    func testSpokenDegenerateInputs() {
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: -5), "0 seconds")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: .nan), "0 seconds")
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: .infinity), "0 seconds")
    }

    func testSpokenRoundsToNearestSecond() {
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 7.6), "8 seconds")
        // Rounding must carry into the minutes field, not print "0 minutes, 60 seconds".
        XCTAssertEqual(VideoDurationFormatter.accessibilityString(from: 59.7), "1 minute")
    }
}
