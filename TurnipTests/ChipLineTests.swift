import CoreGraphics
import XCTest
@testable import Turnip

/// Which chips a one-line row shows, and how wide: whole while they fit, the first that doesn't
/// cut short so it ends in an ellipsis, the rest left out.
final class ChipLineTests: XCTestCase {
    private func widths(_ ideal: [CGFloat], on available: CGFloat) -> [CGFloat?] {
        ChipLine.widths(ideal: ideal, spacing: 4, available: available, minimumCutWidth: 28)
    }

    func testChipsThatFitKeepTheirOwnWidths() {
        XCTAssertEqual(widths([30, 40], on: 100), [30, 40])
        XCTAssertEqual(widths([48, 48], on: 100), [48, 48], "two chips and the gap fill the line exactly")
        XCTAssertEqual(widths([], on: 100), [])
    }

    func testTheFirstChipThatDoesntFitIsCutToTheRoomLeftAndTheRestLeftOut() {
        XCTAssertEqual(widths([30, 80], on: 100), [30, 66])
        XCTAssertEqual(widths([30, 80, 20], on: 100), [30, 66, nil], "a chip after the cut one is left out")
    }

    /// Too little room to show a cut chip's ellipsis: it is left out, and the chip before it is cut
    /// instead, so the line still ends in one.
    func testTooLittleRoomCutsTheChipBefore() {
        XCTAssertEqual(widths([30, 40, 50], on: 100), [30, 39, nil])
    }

    func testAFirstChipWiderThanTheLineIsCutToIt() {
        XCTAssertEqual(widths([150], on: 100), [100])
        XCTAssertEqual(widths([150, 20], on: 100), [100, nil])
    }
}
