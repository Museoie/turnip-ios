import XCTest
@testable import Turnip

/// Pins the arithmetic behind the grid's paging. `reload()` and `loadNextPage()` themselves go
/// through the static `PHAsset.fetchAssets` and a `PHFetchResult` that has no public initializer,
/// so the value seams are the reachable surface — the same shape as `libraryChangeUpdate`.
@MainActor
final class VideoLibraryPagingTests: XCTestCase {
    private let threshold = VideoLibraryViewModel.loadMoreThreshold

    func testTheTileExactlyAtTheThresholdAsksForTheNextPage() {
        XCTAssertTrue(
            VideoLibraryViewModel.shouldLoadNextPage(tileIndex: 60 - threshold, loadedCount: 60))
    }

    func testTheTileOneShortOfTheThresholdDoesNotAskForTheNextPage() {
        XCTAssertFalse(
            VideoLibraryViewModel.shouldLoadNextPage(tileIndex: 60 - threshold - 1, loadedCount: 60))
    }

    func testThePageRangeBeginsWhereTheLoadedPrefixEnds() {
        XCTAssertEqual(
            VideoLibraryViewModel.pageRange(loadedCount: 60, total: 500, pageSize: 60), 60..<120)
    }

    /// The first load is the same arithmetic with nothing loaded yet, which is why there is one
    /// helper rather than two.
    func testTheFirstPageIsAPageStartingAtZero() {
        XCTAssertEqual(
            VideoLibraryViewModel.pageRange(loadedCount: 0, total: 500, pageSize: 60), 0..<60)
    }

    func testThePageRangeStopsAtTheEndOfTheLibrary() {
        XCTAssertEqual(
            VideoLibraryViewModel.pageRange(loadedCount: 60, total: 75, pageSize: 60), 60..<75)
    }

    /// Nil rather than an empty range: a fetch result is never worth asking for zero objects, and
    /// this is the guard that keeps the first load of an empty library from doing it.
    func testThereIsNoPageWhenTheLibraryIsEmpty() {
        XCTAssertNil(VideoLibraryViewModel.pageRange(loadedCount: 0, total: 0, pageSize: 60))
    }

    func testThereIsNoPageOnceEverythingIsLoaded() {
        XCTAssertNil(VideoLibraryViewModel.pageRange(loadedCount: 500, total: 500, pageSize: 60))
    }

    /// A library that shrank under the grid — assets deleted between pages — must not produce a
    /// backwards range: `IndexSet(integersIn:)` traps on one.
    func testThereIsNoPageWhenTheLibraryShrankBelowTheLoadedPrefix() {
        XCTAssertNil(VideoLibraryViewModel.pageRange(loadedCount: 500, total: 120, pageSize: 60))
    }

    // MARK: - Processing's swipe-to-browse neighbor lookup

    func testANegativeOffsetStepsToTheIndexBefore() {
        XCTAssertEqual(
            VideoLibraryViewModel.neighborIndex(currentIndex: 5, offset: -1, count: 10), 4)
    }

    func testAPositiveOffsetStepsToTheIndexAfter() {
        XCTAssertEqual(
            VideoLibraryViewModel.neighborIndex(currentIndex: 5, offset: 1, count: 10), 6)
    }

    func testThereIsNoNeighborBeforeTheFirstVideo() {
        XCTAssertNil(VideoLibraryViewModel.neighborIndex(currentIndex: 0, offset: -1, count: 10))
    }

    func testThereIsNoNeighborAfterTheLastVideo() {
        XCTAssertNil(VideoLibraryViewModel.neighborIndex(currentIndex: 9, offset: 1, count: 10))
    }

    /// Not a wraparound carousel: stepping off either end of the grid stays off it, however far
    /// the offset reaches.
    func testAnOffsetPastBothEndsStaysNil() {
        XCTAssertNil(VideoLibraryViewModel.neighborIndex(currentIndex: 0, offset: -3, count: 10))
        XCTAssertNil(VideoLibraryViewModel.neighborIndex(currentIndex: 9, offset: 3, count: 10))
    }

    func testThereIsNoNeighborInAnEmptyLibrary() {
        XCTAssertNil(VideoLibraryViewModel.neighborIndex(currentIndex: 0, offset: 1, count: 0))
    }

    // MARK: - On-demand prefix growth for a browse past the loaded grid

    func testGrowthReachesExactlyTheRequestedMinimum() {
        XCTAssertEqual(
            VideoLibraryViewModel.growthRange(loadedCount: 60, total: 500, minimumCount: 65), 60..<65)
    }

    /// The range math isn't limited to one page at a time, even though the only real caller
    /// (`browseToNeighbor(of:offset:)`) only ever asks for a single asset past the loaded prefix.
    func testGrowthCanReachPastAFullPage() {
        XCTAssertEqual(
            VideoLibraryViewModel.growthRange(loadedCount: 60, total: 500, minimumCount: 150),
            60..<150)
    }

    func testGrowthStopsAtTheEndOfTheLibrary() {
        XCTAssertEqual(
            VideoLibraryViewModel.growthRange(loadedCount: 60, total: 75, minimumCount: 200), 60..<75)
    }

    func testThereIsNoGrowthOnceTheLoadedPrefixAlreadyReachesTheMinimum() {
        XCTAssertNil(
            VideoLibraryViewModel.growthRange(loadedCount: 60, total: 500, minimumCount: 60))
    }

    /// The same shrink guard as `pageRange`: a library that lost assets between browses must
    /// not produce a backwards range.
    func testThereIsNoGrowthWhenTheLibraryShrankBelowTheLoadedPrefix() {
        XCTAssertNil(
            VideoLibraryViewModel.growthRange(loadedCount: 500, total: 120, minimumCount: 600))
    }
}
