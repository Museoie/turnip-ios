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
}
