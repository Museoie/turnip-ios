import XCTest
@testable import Turnip

/// Pins the two decisions `VideoLibraryViewModel.apply(_:)` makes about a `PHChange`. `PHChange`
/// itself has no public initializer, so this is the seam.
@MainActor
final class VideoLibraryChangeUpdateTests: XCTestCase {
    func testPrefixNeverShrinksBelowWhatTheUserHasScrolledThrough() {
        let update = VideoLibraryViewModel.libraryChangeUpdate(
            loadedCount: 180,
            hasIncrementalChanges: true,
            changedIdentifiers: { [] }
        )

        XCTAssertEqual(update.prefixCount, 180)
    }

    func testPrefixIsAtLeastOnePageWhenLessThanAPageIsLoaded() {
        let update = VideoLibraryViewModel.libraryChangeUpdate(
            loadedCount: 4,
            hasIncrementalChanges: true,
            changedIdentifiers: { [] }
        )

        XCTAssertEqual(update.prefixCount, VideoLibraryViewModel.pageSize)
    }

    func testIncrementalChangeInvalidatesExactlyTheChangedAssets() {
        let update = VideoLibraryViewModel.libraryChangeUpdate(
            loadedCount: 60,
            hasIncrementalChanges: true,
            changedIdentifiers: { ["asset-3", "asset-7"] }
        )

        XCTAssertEqual(update.invalidatedIdentifiers, ["asset-3", "asset-7"])
    }

    func testNonIncrementalChangeInvalidatesNothingAndNeverReadsChangedObjects() {
        // `changedObjects` is only populated for an incremental change; reading it otherwise would
        // invalidate an arbitrary set of tiles.
        var readChangedObjects = false
        let update = VideoLibraryViewModel.libraryChangeUpdate(
            loadedCount: 60,
            hasIncrementalChanges: false,
            changedIdentifiers: {
                readChangedObjects = true
                return ["asset-3"]
            }
        )

        XCTAssertTrue(update.invalidatedIdentifiers.isEmpty)
        XCTAssertFalse(readChangedObjects)
    }
}
