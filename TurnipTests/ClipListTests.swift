import AVFoundation
import CoreGraphics
import XCTest
@testable import Turnip

final class ClipListTests: XCTestCase {
    private let window = TrickWindow(startTime: 2, endTime: 5)
    private let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)

    private func makeItem(isKept: Bool = true) -> ClipListItem {
        ClipListItem(window: window, cropRect: fullFrame, isKept: isKept)
    }

    /// A 90°-rotated track's preferredTransform: landscape-encoded portrait video.
    /// Encoded (0,0) is the displayed top-right, so it discriminates transforms that mix up
    /// encoded and displayed space.
    private let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    // MARK: - ClipListItem

    func testNewItemsStartKept() {
        // docs/UIUX.md's resolved open question #2: every clip starts kept.
        XCTAssertTrue(makeItem().isKept)
    }

    func testDurationLabelShowsOneDecimalSecond() {
        XCTAssertEqual(makeItem().durationLabel, "3.0s")
    }

    func testDurationLabelRoundsToOneDecimal() {
        let item = ClipListItem(
            window: TrickWindow(startTime: 1, endTime: 3.35), cropRect: fullFrame)
        XCTAssertEqual(item.durationLabel, "2.4s")
    }

    // MARK: - ClipListViewModel

    @MainActor
    func testToggleKeepFlipsOnlyTheTappedCard() {
        let first = makeItem(), second = makeItem()
        let viewModel = ClipListViewModel(items: [first, second], asset: AVAsset())

        viewModel.toggleKeep(first)

        XCTAssertFalse(viewModel.items[0].isKept)
        XCTAssertTrue(viewModel.items[1].isKept)

        viewModel.toggleKeep(first)
        XCTAssertTrue(viewModel.items[0].isKept)
    }

    @MainActor
    func testToggleKeepIgnoresUnknownItems() {
        let viewModel = ClipListViewModel(items: [makeItem()], asset: AVAsset())

        viewModel.toggleKeep(makeItem())

        XCTAssertTrue(viewModel.items[0].isKept)
    }

    @MainActor
    func testExportTitleCountsKeptClips() {
        let viewModel = ClipListViewModel(
            items: [makeItem(), makeItem(isKept: false)], asset: AVAsset())

        XCTAssertEqual(viewModel.exportTitle, "Export 1 clip")
        XCTAssertTrue(viewModel.canExport)
        XCTAssertEqual(viewModel.keptItems.count, 1)
    }

    @MainActor
    func testExportDisabledWhenEveryClipIsDiscarded() {
        let viewModel = ClipListViewModel(items: [makeItem(isKept: false)], asset: AVAsset())

        XCTAssertEqual(viewModel.exportTitle, "Export 0 clips")
        XCTAssertFalse(viewModel.canExport)
        XCTAssertTrue(viewModel.keptItems.isEmpty)
    }

    // MARK: - ClipThumbnailLoader.displayedCropRect

    func testDisplayedCropRectWithIdentityTransformIsUnchanged() {
        // Fractions chosen exactly representable in Float so the assertion is exact —
        // the point here is the space mapping, not float dust.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.5, maxY: 0.75)

        let rect = ClipThumbnailLoader.displayedCropRect(
            cropRect: crop,
            naturalSize: CGSize(width: 200, height: 100),
            preferredTransform: .identity)

        XCTAssertEqual(rect, CGRect(x: 50, y: 50, width: 100, height: 25))
    }

    func testDisplayedCropRectMapsARotatedTrackIntoDisplayedSpace() {
        // Full encoded frame must become the portrait displayed frame.
        let full = ClipThumbnailLoader.displayedCropRect(
            cropRect: fullFrame,
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)
        XCTAssertEqual(full, CGRect(x: 0, y: 0, width: 1080, height: 1920))

        // The encoded left half (x in 0..<960) maps through (x, y) -> (1080 - y, x) onto
        // the displayed top half. A transform applied in the wrong space would land the
        // crop on the wrong half — this is the discriminating case.
        let leftHalf = NormalizedRect(minX: 0, maxX: 0.5, minY: 0, maxY: 1)
        let rect = ClipThumbnailLoader.displayedCropRect(
            cropRect: leftHalf,
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1080, height: 960))
    }

    func testDisplayedCropRectReturnsNilForDegenerateInputs() {
        XCTAssertNil(ClipThumbnailLoader.displayedCropRect(
            cropRect: fullFrame,
            naturalSize: .zero,
            preferredTransform: .identity))

        let empty = NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0, maxY: 1)
        XCTAssertNil(ClipThumbnailLoader.displayedCropRect(
            cropRect: empty,
            naturalSize: CGSize(width: 100, height: 100),
            preferredTransform: .identity))
    }

    // MARK: - ClipThumbnailLoader.croppedThumbnail

    func testCroppedThumbnailExtractsTheDisplayedCropAtPixelScale() throws {
        // 4x2 test image; the crop is given in displayed space (8x4), so the loader must
        // scale it down to the image's pixels. Forgetting the scale would crop outside the
        // image and return nil instead of a 2x2 thumbnail.
        let image = try XCTUnwrap(Self.testImage(width: 4, height: 2))

        let cropped = ClipThumbnailLoader.croppedThumbnail(
            image,
            to: CGRect(x: 4, y: 0, width: 4, height: 4),
            in: CGSize(width: 8, height: 4))

        XCTAssertEqual(cropped?.width, 2)
        XCTAssertEqual(cropped?.height, 2)
    }

    func testCroppedThumbnailReturnsNilWhenNothingSurvivesTheClamp() throws {
        let image = try XCTUnwrap(Self.testImage(width: 4, height: 2))

        // Entirely outside the displayed frame.
        XCTAssertNil(ClipThumbnailLoader.croppedThumbnail(
            image,
            to: CGRect(x: 100, y: 100, width: 10, height: 10),
            in: CGSize(width: 8, height: 4)))
        // Degenerate displayed size.
        XCTAssertNil(ClipThumbnailLoader.croppedThumbnail(
            image,
            to: CGRect(x: 0, y: 0, width: 4, height: 4),
            in: .zero))
    }

    // MARK: - ClipThumbnailLoader.thumbnail

    func testThumbnailReturnsNilWhenTheAssetHasNoVideoTrack() async {
        let loader = ClipThumbnailLoader()

        let result = await loader.thumbnail(for: makeItem(), in: AVAsset())

        // The card falls back to its placeholder tile; a throw must never reach the view.
        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private static func testImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }
}
