import SwiftUI
import XCTest
@testable import Turnip

/// The root screen's layout decisions, each a pure function of one input: the page the app opens
/// on, whether the safe area holds iPhone Duo's vertical bar and on which side, and how many
/// columns the gallery lays out across a width.
@MainActor
final class RootNavigationTests: XCTestCase {
    // MARK: - Landing page

    /// An in-memory library: nothing read from or written to disk.
    private func makeLibrary() -> ClipLibrary {
        ClipLibrary(fileURL: nil, vocabulary: { .seed }, announce: { _ in })
    }

    func testOpensOnTheGalleryBeforeAnyClipIsSaved() {
        XCTAssertEqual(MainTab.landing(for: makeLibrary()), .home)
    }

    func testOpensOnTheProfileOnceAClipIsSaved() {
        let library = makeLibrary()
        let clip = LibrarySave.Clip(
            id: UUID(), window: TrickWindow(startTime: 4, endTime: 5.5), exportAssetID: "export-1",
            names: [], isMe: true, isAutoDetected: true, proposal: nil)
        library.record(
            LibrarySave(sourceAssetID: "source-1", sourceDuration: 30, clips: [clip]), sourceRecordedAt: Date())
        XCTAssertEqual(MainTab.landing(for: library), .profile)
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

    /// `VerticalBar.minimumWidth` is the line: an inset that much wider than the other side's is a bar,
    /// and one a point narrower isn't — on either side.
    func testAnInsetExactlyTheMinimumWidthWiderIsAVerticalBar() {
        let trailing = VerticalBar(safeAreaInsets: EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 44))
        XCTAssertEqual(trailing, VerticalBar(edge: .trailing, width: 44))
        XCTAssertNil(VerticalBar(safeAreaInsets: EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 43)))

        let leading = VerticalBar(safeAreaInsets: EdgeInsets(top: 20, leading: 44, bottom: 20, trailing: 0))
        XCTAssertEqual(leading, VerticalBar(edge: .leading, width: 44))
        XCTAssertNil(VerticalBar(safeAreaInsets: EdgeInsets(top: 20, leading: 43, bottom: 20, trailing: 0)))
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

    // MARK: - Where the column's controls start

    func testNoStatusBarFrameKeepsTheFloor() {
        XCTAssertEqual(VerticalBar.controlsTop(statusBar: nil, windowHeight: 667), VerticalBar.statusBarFloor)
        XCTAssertEqual(VerticalBar.controlsTop(statusBar: .zero, windowHeight: 667), VerticalBar.statusBarFloor)
    }

    /// The strip across the top that a status bar has always been ends above the floor.
    func testAStatusBarStripKeepsTheFloor() {
        let strip = CGRect(x: 0, y: 0, width: 458, height: 54)
        XCTAssertEqual(VerticalBar.controlsTop(statusBar: strip, windowHeight: 667), VerticalBar.statusBarFloor)
    }

    func testAStatusBarReachingPastTheFloorMovesTheControlsUnderIt() {
        let column = CGRect(x: 374, y: 0, width: 84, height: 200)
        XCTAssertEqual(VerticalBar.controlsTop(statusBar: column, windowHeight: 667), 200)
    }

    /// `VerticalBar.statusBarMaximumShare` is the line: a frame ending exactly a third of the window
    /// down still counts, and one a point deeper doesn't.
    func testAStatusBarEndingExactlyAThirdOfTheWindowDownStillCounts() {
        let atTheLine = CGRect(x: 374, y: 0, width: 84, height: 200)
        XCTAssertEqual(VerticalBar.controlsTop(statusBar: atTheLine, windowHeight: 600), 200)
        let pastTheLine = CGRect(x: 374, y: 0, width: 84, height: 201)
        XCTAssertEqual(
            VerticalBar.controlsTop(statusBar: pastTheLine, windowHeight: 600), VerticalBar.statusBarFloor)
    }

    /// A frame spanning the whole column would put the controls off the bottom of the screen.
    func testAStatusBarSpanningTheColumnIsIgnored() {
        let wholeColumn = CGRect(x: 374, y: 0, width: 84, height: 667)
        XCTAssertEqual(
            VerticalBar.controlsTop(statusBar: wholeColumn, windowHeight: 667), VerticalBar.statusBarFloor)
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
