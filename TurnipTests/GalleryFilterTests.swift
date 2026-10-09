import XCTest
@testable import Turnip

/// `GalleryFilter`'s predicate mapping is the reachable, testable seam — the `.album` case
/// carries a `PHAssetCollection`, which has no public initializer, the same reason
/// `VideoLibraryPagingTests` tests arithmetic rather than a real `PHFetchResult`. `.album`'s
/// `==` branch (`localIdentifier` comparison) is exercised by the compiler's exhaustiveness
/// check on the switch, not a unit test here: `PHAssetCollection.transientAssetCollection`
/// could construct one without a real library, but whether its `localIdentifier` is stable or
/// freshly generated per call is undocumented, and a wrong guess would make the test lie either
/// way — not tested rather than tested on an unverified assumption.
final class GalleryFilterTests: XCTestCase {
    func testAllRestrictsToVideosOnly() {
        let format = GalleryFilter.all.predicate.predicateFormat
        XCTAssertTrue(format.contains("mediaType == 2"), format)
        XCTAssertFalse(format.contains("favorite"), format)
    }

    func testFavoritesRestrictsToVideosAndFavorited() {
        let format = GalleryFilter.favorites.predicate.predicateFormat
        XCTAssertTrue(format.contains("mediaType == 2"), format)
        XCTAssertTrue(format.contains("favorite == 1"), format)
    }

    func testAllEqualsItself() {
        XCTAssertEqual(GalleryFilter.all, GalleryFilter.all)
    }

    func testFavoritesEqualsItself() {
        XCTAssertEqual(GalleryFilter.favorites, GalleryFilter.favorites)
    }

    func testAllIsNotEqualToFavorites() {
        XCTAssertNotEqual(GalleryFilter.all, GalleryFilter.favorites)
    }

    func testAllLabelIsAllItems() {
        XCTAssertEqual(GalleryFilter.all.label, "All Items")
    }

    func testFavoritesLabelIsFavorites() {
        XCTAssertEqual(GalleryFilter.favorites.label, "Favorites")
    }
}
