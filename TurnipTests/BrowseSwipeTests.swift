import XCTest
@testable import Turnip

final class BrowseSwipeTests: XCTestCase {

    // MARK: - The page follows the finger

    func testThePageFollowsARightDragOneToOneWhenThereIsAPreviousVideo() {
        XCTAssertEqual(
            BrowseSwipe.pageOffset(translation: 140, hasPrevious: true, hasNext: true), 140)
    }

    func testThePageFollowsALeftDragOneToOneWhenThereIsANextVideo() {
        XCTAssertEqual(
            BrowseSwipe.pageOffset(translation: -140, hasPrevious: true, hasNext: true), -140)
    }

    /// At the newest end of the grid a rightward drag has nowhere to land, so the page only
    /// gives a little — and still in the direction the finger moved, not against it.
    func testARightDragAtTheNewestEndOfTheGridMovesTheShortenedDistance() {
        let offset = BrowseSwipe.pageOffset(translation: 140, hasPrevious: false, hasNext: true)
        XCTAssertEqual(offset, 140 * BrowseSwipe.endOfGridResistance)
        XCTAssertGreaterThan(offset, 0)
        XCTAssertLessThan(offset, 140)
    }

    func testALeftDragAtTheOldestEndOfTheGridMovesTheShortenedDistance() {
        let offset = BrowseSwipe.pageOffset(translation: -140, hasPrevious: true, hasNext: false)
        XCTAssertEqual(offset, -140 * BrowseSwipe.endOfGridResistance)
        XCTAssertLessThan(offset, 0)
        XCTAssertGreaterThan(offset, -140)
    }

    /// The direction with a neighbor is unaffected by the other end of the grid being reached.
    func testTheShortenedTravelAppliesOnlyToTheDirectionWithNoNeighbor() {
        XCTAssertEqual(
            BrowseSwipe.pageOffset(translation: -140, hasPrevious: false, hasNext: true), -140)
        XCTAssertEqual(
            BrowseSwipe.pageOffset(translation: 140, hasPrevious: true, hasNext: false), 140)
    }

    func testAnUnmovedDragLeavesThePageWhereItIs() {
        XCTAssertEqual(
            BrowseSwipe.pageOffset(translation: 0, hasPrevious: true, hasNext: true), 0)
    }

    /// A drag below the commit distance still moves the page: the feedback is what says the
    /// swipe was seen, whether or not it will land.
    func testAShortDragStillMovesThePage() {
        XCTAssertEqual(
            BrowseSwipe.pageOffset(translation: 12, hasPrevious: true, hasNext: true), 12)
    }

    // MARK: - What letting go commits to

    func testARightDragPastTheCommitDistanceBrowsesToThePreviousVideo() {
        XCTAssertEqual(
            BrowseSwipe.commit(translation: 140, hasPrevious: true, hasNext: true), .previous)
    }

    func testALeftDragPastTheCommitDistanceBrowsesToTheNextVideo() {
        XCTAssertEqual(
            BrowseSwipe.commit(translation: -140, hasPrevious: true, hasNext: true), .next)
    }

    func testADragExactlyAtTheCommitDistanceBrowses() {
        XCTAssertEqual(
            BrowseSwipe.commit(
                translation: BrowseSwipe.commitDistance, hasPrevious: true, hasNext: true),
            .previous)
    }

    func testADragShortOfTheCommitDistanceSpringsBackInsteadOfBrowsing() {
        XCTAssertNil(
            BrowseSwipe.commit(
                translation: BrowseSwipe.commitDistance - 1, hasPrevious: true, hasNext: true))
        XCTAssertNil(
            BrowseSwipe.commit(
                translation: -(BrowseSwipe.commitDistance - 1), hasPrevious: true, hasNext: true))
    }

    func testAnUnmovedDragCommitsToNothing() {
        XCTAssertNil(BrowseSwipe.commit(translation: 0, hasPrevious: true, hasNext: true))
    }

    /// Not a wraparound carousel: a long drag off either end of the grid stays on the video
    /// it started on.
    func testADragOffTheNewestEndOfTheGridCommitsToNothing() {
        XCTAssertNil(BrowseSwipe.commit(translation: 300, hasPrevious: false, hasNext: true))
    }

    func testADragOffTheOldestEndOfTheGridCommitsToNothing() {
        XCTAssertNil(BrowseSwipe.commit(translation: -300, hasPrevious: true, hasNext: false))
    }

    func testNeitherDirectionCommitsWhenTheGridHoldsOnlyThisVideo() {
        XCTAssertNil(BrowseSwipe.commit(translation: 300, hasPrevious: false, hasNext: false))
        XCTAssertNil(BrowseSwipe.commit(translation: -300, hasPrevious: false, hasNext: false))
    }
}

// MARK: - A flick commits a short drag

extension BrowseSwipeTests {
    /// A quick flick lifts well short of `commitDistance`, but its projected end reaches far
    /// past the page — the pager feel, where a fast short swipe turns the page.
    func testAFlickShortOfTheCommitDistanceBrowsesWhenItsProjectedEndReachesFarEnough() {
        XCTAssertEqual(
            BrowseSwipe.commit(
                translation: 30, predictedTranslation: BrowseSwipe.flickDistance,
                hasPrevious: true, hasNext: true),
            .previous)
        XCTAssertEqual(
            BrowseSwipe.commit(
                translation: -30, predictedTranslation: -BrowseSwipe.flickDistance,
                hasPrevious: true, hasNext: true),
            .next)
    }

    func testASlowShortDragSpringsBackEvenWithItsProjectedEndKnown() {
        XCTAssertNil(
            BrowseSwipe.commit(
                translation: 30, predictedTranslation: BrowseSwipe.flickDistance - 1,
                hasPrevious: true, hasNext: true))
    }

    /// A finger that reverses before lifting projects the other way; that is not a flick
    /// toward the neighbor the drag uncovered.
    func testAFlickProjectedAgainstTheDragDirectionSpringsBack() {
        XCTAssertNil(
            BrowseSwipe.commit(
                translation: 30, predictedTranslation: -BrowseSwipe.flickDistance,
                hasPrevious: true, hasNext: true))
    }

    func testAFlickOffTheEndOfTheGridCommitsToNothing() {
        XCTAssertNil(
            BrowseSwipe.commit(
                translation: 30, predictedTranslation: BrowseSwipe.flickDistance,
                hasPrevious: false, hasNext: true))
    }

    /// The projection never overrides a drag that already travelled far enough.
    func testADragPastTheCommitDistanceBrowsesWhateverItsProjectedEnd() {
        XCTAssertEqual(
            BrowseSwipe.commit(
                translation: BrowseSwipe.commitDistance, predictedTranslation: 0,
                hasPrevious: true, hasNext: true),
            .previous)
    }
}
