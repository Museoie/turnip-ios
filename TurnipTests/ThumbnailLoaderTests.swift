import Photos
import UIKit
import XCTest
@testable import Turnip

final class ThumbnailLoaderTests: XCTestCase {
    func testPrefetchRangeIsCenteredAndClampedToBounds() {
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 50, count: 200, radius: 10), 40..<61)
        // Near the start: clamps at 0, does not shift the upper bound to compensate.
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 3, count: 200, radius: 10), 0..<14)
        // Near the end: clamps at count.
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 195, count: 200, radius: 10), 185..<200)
        // Window larger than the list: the whole list.
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 2, count: 5, radius: 10), 0..<5)
    }

    func testPrefetchRangeHandlesDegenerateInputs() {
        XCTAssertTrue(ThumbnailLoader.prefetchRange(around: 0, count: 0, radius: 10).isEmpty)
        // An out-of-range index (stale after a library change) is clamped rather than trapping.
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 500, count: 20, radius: 3), 16..<20)
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: -4, count: 20, radius: 3), 0..<4)
        XCTAssertEqual(ThumbnailLoader.prefetchRange(around: 5, count: 20, radius: 0), 5..<6)
    }
}

/// Exercises the caching calls themselves rather than the window arithmetic: which assets are
/// handed to `startCachingImages` / `stopCachingImages`, and when the cache is dropped wholesale.
@MainActor
final class ThumbnailLoaderCachingTests: XCTestCase {
    private var manager: RecordingCachingImageManager!
    private var loader: ThumbnailLoader!

    override func setUp() {
        super.setUp()
        manager = RecordingCachingImageManager()
        loader = ThumbnailLoader(manager: manager)
    }

    func testNothingIsCachedUntilATileHasRequestedAnImage() {
        // The tile size is learned from the first request; before it there is no size to cache at.
        loader.tileAppeared(at: 40, in: assets(count: 200))

        XCTAssertTrue(manager.started.isEmpty)
        XCTAssertTrue(manager.stopped.isEmpty)
    }

    func testFirstWindowCachesExactlyTheClampedRange() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])

        loader.tileAppeared(at: 40, in: list)

        XCTAssertEqual(manager.started.count, 1)
        XCTAssertEqual(manager.started.first, (22...58).map { "asset-\($0)" })
        XCTAssertTrue(manager.stopped.isEmpty)
    }

    func testScrollingOneTileCachesOneAssetAndStopsOne() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)

        loader.tileAppeared(at: 41, in: list)

        XCTAssertEqual(manager.started.last, ["asset-59"])
        XCTAssertEqual(manager.stopped.last, ["asset-22"])
    }

    func testTilesResolvingToTheSameWindowIssueCachingWorkOnlyOnce() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)
        let startedCount = manager.started.count

        // In a list shorter than the window both indexes clamp to the same range, so only the
        // first may re-issue caching calls.
        loader.tileAppeared(at: 41, in: assets(count: 10))
        loader.tileAppeared(at: 42, in: assets(count: 10))

        XCTAssertEqual(manager.started.count, startedCount + 1)
    }

    func testContentOnlyLibraryChangeKeepsTheWindowWarmAndRefreshesOnlyChangedAssets() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)

        loader.replaceAssets(list, invalidating: ["asset-40"])

        XCTAssertEqual(manager.stoppedAllCount, 0, "a content-only change must not empty the cache")
        XCTAssertEqual(manager.stopped.last, ["asset-40"])
        XCTAssertEqual(manager.started.last, ["asset-40"])
    }

    func testInsertionShiftsTheWindowByExactlyTheAssetsThatCrossedItsEdges() {
        var list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)

        list.insert(StubAsset("asset-new"), at: 0)
        loader.replaceAssets(list, invalidating: [])

        XCTAssertEqual(manager.started.last, ["asset-21"])
        XCTAssertEqual(manager.stopped.last, ["asset-58"])
    }

    func testReplacingAssetsBeforeAnyTileAppearedFallsBackToDroppingTheCache() {
        loader.replaceAssets(assets(count: 10), invalidating: [])

        XCTAssertEqual(manager.stoppedAllCount, 1)
        XCTAssertTrue(manager.started.isEmpty)
    }

    func testResetDropsTheWholeCacheAndTheWindowRebuildsFromScratch() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)

        loader.reset()
        loader.tileAppeared(at: 40, in: list)

        XCTAssertEqual(manager.stoppedAllCount, 1)
        XCTAssertEqual(manager.started.last, (22...58).map { "asset-\($0)" })
    }

    func testContentOnlyChangeBumpsTheRevisionOfExactlyTheChangedAsset() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)
        let before = list.map { loader.revision(for: $0) }

        loader.replaceAssets(list, invalidating: ["asset-40"])

        let bumped = zip(list, before)
            .filter { loader.revision(for: $0.0) != $0.1 }
            .map(\.0.localIdentifier)
        XCTAssertEqual(bumped, ["asset-40"])
        XCTAssertEqual(loader.revision(for: list[40]), before[40] + 1)
    }

    func testASecondChangeToTheSameAssetBumpsAgainSoTheTileRepaintsTwice() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)

        loader.replaceAssets(list, invalidating: ["asset-40"])
        let afterFirst = loader.revision(for: list[40])
        loader.replaceAssets(list, invalidating: ["asset-40"])

        XCTAssertEqual(loader.revision(for: list[40]), afterFirst + 1)
    }

    func testAChangeOutsideTheWindowBumpsNothingSinceNoTileIsShowingIt() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)

        loader.replaceAssets(list, invalidating: ["asset-150"])

        XCTAssertEqual(list.map { loader.revision(for: $0) }, Array(repeating: 0, count: list.count))
    }

    func testScrollingAndUninvalidatedReplacementLeaveEveryRevisionAlone() {
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)

        loader.tileAppeared(at: 41, in: list)
        loader.replaceAssets(list, invalidating: [])

        XCTAssertEqual(list.map { loader.revision(for: $0) }, Array(repeating: 0, count: list.count))
    }

    func testAChangeThatLandsBeforeTheWindowIsRebuiltStillBumpsTheChangedAsset() {
        // Between a reload and the next tile appearance there is no window to re-cache against, but
        // the tiles on screen keep their identities and their images, so the counter still has to move.
        let list = assets(count: 200)
        primeTileSize(with: list[0])
        loader.tileAppeared(at: 40, in: list)
        loader.reset()

        loader.replaceAssets(list, invalidating: ["asset-40"])

        let bumped = list.filter { loader.revision(for: $0) != 0 }.map(\.localIdentifier)
        XCTAssertEqual(bumped, ["asset-40"])
        XCTAssertEqual(manager.stoppedAllCount, 2)
        XCTAssertEqual(manager.started.count, 1)
    }

    // MARK: - Fixtures

    private func assets(count: Int) -> [PHAsset] {
        (0..<count).map { StubAsset("asset-\($0)") }
    }

    private func primeTileSize(with asset: PHAsset) {
        _ = loader.requestImage(for: asset, pixelSize: CGSize(width: 120, height: 120)) { _, _ in }
    }
}

/// A `PHAsset` that carries nothing but a `localIdentifier`, which is the only property the window
/// diffing reads.
private final class StubAsset: PHAsset {
    private let identifier: String

    init(_ identifier: String) {
        self.identifier = identifier
        super.init()
    }

    override var localIdentifier: String { identifier }
}

/// Records the caching calls by identifier so they can be asserted without a real photo library.
private final class RecordingCachingImageManager: PHCachingImageManager {
    private(set) var started: [[String]] = []
    private(set) var stopped: [[String]] = []
    private(set) var stoppedAllCount = 0

    override func startCachingImages(
        for assets: [PHAsset], targetSize: CGSize, contentMode: PHImageContentMode,
        options: PHImageRequestOptions?
    ) {
        started.append(assets.map(\.localIdentifier))
    }

    override func stopCachingImages(
        for assets: [PHAsset], targetSize: CGSize, contentMode: PHImageContentMode,
        options: PHImageRequestOptions?
    ) {
        stopped.append(assets.map(\.localIdentifier))
    }

    override func stopCachingImagesForAllAssets() {
        stoppedAllCount += 1
    }

    override func requestImage(
        for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode,
        options: PHImageRequestOptions?, resultHandler: @escaping (UIImage?, [AnyHashable: Any]?) -> Void
    ) -> PHImageRequestID {
        0
    }
}
