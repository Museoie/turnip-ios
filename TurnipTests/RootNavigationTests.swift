import SwiftUI
import XCTest
@testable import Turnip

/// The root screen's layout decisions, each a pure function of one input: the page the app opens
/// on, whether the safe area holds iPhone Duo's vertical bar and on which side, and how many
/// columns the gallery lays out across a width.
@MainActor
final class RootNavigationTests: XCTestCase {
    // MARK: - Landing page

    func testOpensOnTheGalleryBeforeAnyClipIsSaved() {
        XCTAssertEqual(MainTab.landing(hasSavedClips: false), .home)
    }

    func testOpensOnTheProfileOnceAClipIsSaved() {
        XCTAssertEqual(MainTab.landing(hasSavedClips: true), .profile)
    }

    // MARK: - Vertical bar

    func testNoSideInsetsIsNoVerticalBar() {
        XCTAssertNil(VerticalBar(safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)))
    }

    func testEqualSideInsetsAreAMarginNotAVerticalBar() {
        XCTAssertNil(VerticalBar(safeAreaInsets: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)))
    }

    func testANarrowOneSidedInsetIsNotAVerticalBar() {
        XCTAssertNil(VerticalBar(safeAreaInsets: EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 20)))
    }

    func testAWideTrailingInsetIsATrailingVerticalBar() {
        let bar = VerticalBar(safeAreaInsets: EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 84))
        XCTAssertEqual(bar, VerticalBar(edge: .trailing, width: 84))
    }

    func testAWideLeadingInsetIsALeadingVerticalBar() {
        let bar = VerticalBar(safeAreaInsets: EdgeInsets(top: 20, leading: 84, bottom: 20, trailing: 0))
        XCTAssertEqual(bar, VerticalBar(edge: .leading, width: 84))
    }

    /// The bar is the whole inset on its side, not its difference from the other side's.
    func testTheBarIsAsWideAsItsWholeInset() {
        let bar = VerticalBar(safeAreaInsets: EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 84))
        XCTAssertEqual(bar, VerticalBar(edge: .trailing, width: 84))
    }

    // MARK: - Gallery columns

    func testEveryIPhoneHeldUprightKeepsThreeColumns() {
        for width: CGFloat in [320, 375, 393, 402, 430, 440] {
            XCTAssertEqual(VideoGalleryView.columnCount(forWidth: width), 3, "at \(width) pt")
        }
    }

    /// Beside iPhone Duo's vertical bar the outer display's grid is narrower than any other
    /// iPhone's, and still three columns.
    func testANarrowGridKeepsThreeColumns() {
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 374), 3)
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 0), 3)
    }

    func testWiderGridsGainColumnsUpToSix() {
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 517), 3)
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 518), 4)
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 647), 4)
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 648), 5)
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 777), 5)
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 778), 6)
    }

    func testAVeryWideGridStopsAtSixColumns() {
        XCTAssertEqual(VideoGalleryView.columnCount(forWidth: 1_366), 6)
    }
}
