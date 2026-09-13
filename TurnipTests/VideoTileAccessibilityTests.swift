import XCTest
@testable import Turnip

/// The tile's VoiceOver label is the accessibility contract for the Home grid — a wording
/// regression here is silent (nothing crashes, VoiceOver just announces the wrong thing), so the
/// label builder gets the same assertion treatment as any other behavior. Date formatting is
/// locale-dependent, so date-bearing cases assert structure rather than exact wording.
final class VideoTileAccessibilityTests: XCTestCase {
    func testLabelWithoutDate() {
        XCTAssertEqual(
            VideoTileView.accessibilityLabel(
                spokenDuration: "12 seconds",
                creationDate: nil,
                isResolving: false
            ),
            "Video, 12 seconds"
        )
    }

    func testLabelAppendsLoadingWhileResolving() {
        XCTAssertEqual(
            VideoTileView.accessibilityLabel(
                spokenDuration: "12 seconds",
                creationDate: nil,
                isResolving: true
            ),
            "Video, 12 seconds, loading"
        )
    }

    func testLabelIncludesCreationDate() {
        let date = Date(timeIntervalSince1970: 1_725_000_000)
        let label = VideoTileView.accessibilityLabel(
            spokenDuration: "12 seconds",
            creationDate: date,
            isResolving: false
        )
        XCTAssertTrue(label.hasPrefix("Video, 12 seconds, "))
        // The date must add something beyond the no-date label — an empty or dropped date
        // would silently produce the no-date wording.
        XCTAssertNotEqual(label, "Video, 12 seconds")
        XCTAssertFalse(label.contains("loading"))
    }

    func testLabelWithDateAndResolving() {
        let date = Date(timeIntervalSince1970: 1_725_000_000)
        let label = VideoTileView.accessibilityLabel(
            spokenDuration: "1 minute, 5 seconds",
            creationDate: date,
            isResolving: true
        )
        XCTAssertTrue(label.hasPrefix("Video, 1 minute, 5 seconds, "))
        XCTAssertTrue(label.hasSuffix(", loading"))
    }
}
