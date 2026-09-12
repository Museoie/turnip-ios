import AVFoundation
import CoreGraphics
import SwiftUI
import XCTest
@testable import Turnip

final class ClipListTests: XCTestCase {
    private let window = TrickWindow(startTime: 2, endTime: 5)
    private let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)

    private func makeItem(isKept: Bool = true) -> ClipListItem {
        ClipListItem(window: window, cropRect: fullFrame, isKept: isKept)
    }

    /// `AVAsset` is abstract and throws at runtime, so the view-model tests use the
    /// concrete `AVURLAsset` subclass. The URL resolves to nothing — these tests never
    /// decode, they only exercise the keep/discard and export-title logic.
    private func dummyAsset() -> AVURLAsset {
        AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
    }

    /// A 90°-rotated track's preferredTransform: landscape-encoded portrait video.
    /// Encoded (0,0) is the displayed top-right, so it discriminates transforms that mix up
    /// encoded and displayed space.
    private let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    // MARK: - ClipListItem

    func testNewItemsStartKept() {
        // The resolved bulk keep/discard decision in docs/UIUX.md: every clip starts kept.
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
        let viewModel = ClipListViewModel(items: [first, second], asset: dummyAsset())

        viewModel.toggleKeep(first)

        XCTAssertFalse(viewModel.items[0].isKept)
        XCTAssertTrue(viewModel.items[1].isKept)

        viewModel.toggleKeep(first)
        XCTAssertTrue(viewModel.items[0].isKept)
    }

    @MainActor
    func testToggleKeepIgnoresUnknownItems() {
        let viewModel = ClipListViewModel(items: [makeItem()], asset: dummyAsset())

        viewModel.toggleKeep(makeItem())

        XCTAssertTrue(viewModel.items[0].isKept)
    }

    @MainActor
    func testBindingWritesThroughToTheListEntry() {
        let target = makeItem()
        let viewModel = ClipListViewModel(items: [makeItem(), target], asset: dummyAsset())

        guard let binding = viewModel.binding(for: target.id) else {
            XCTFail("expected a binding for an item that is in the list")
            return
        }
        binding.wrappedValue.isKept = false

        // The write lands on the target entry, not on whichever index the binding was
        // created at — the editor destination edits the clip the card tapped.
        XCTAssertFalse(viewModel.items[1].isKept)
        XCTAssertTrue(viewModel.items[0].isKept)
    }

    @MainActor
    func testBindingIsNilForAnItemThatIsNotInTheList() {
        let viewModel = ClipListViewModel(items: [makeItem()], asset: dummyAsset())

        XCTAssertNil(viewModel.binding(for: makeItem().id))
    }

    @MainActor
    func testExportTitleCountsKeptClips() {
        let viewModel = ClipListViewModel(
            items: [makeItem(), makeItem(isKept: false)], asset: dummyAsset())

        XCTAssertEqual(viewModel.exportTitle, "Export 1 clip")
        XCTAssertTrue(viewModel.canExport)
        XCTAssertEqual(viewModel.keptItems.count, 1)
    }

    @MainActor
    func testExportDisabledWhenEveryClipIsDiscarded() {
        let viewModel = ClipListViewModel(items: [makeItem(isKept: false)], asset: dummyAsset())

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

        let cropped = try XCTUnwrap(ClipThumbnailLoader.croppedThumbnail(
            image,
            to: CGRect(x: 4, y: 0, width: 4, height: 4),
            in: CGSize(width: 8, height: 4)))

        XCTAssertEqual(cropped.width, 2)
        XCTAssertEqual(cropped.height, 2)

        // The crop is the right half of the displayed frame. Reading a pixel proves the
        // *region* was extracted, not just the size: an implementation that dropped the
        // crop's minX/minY and always cropped from the origin would read the red left
        // half here instead of the green right half.
        let pixel = try XCTUnwrap(Self.pixel(atX: 0, y: 0, in: cropped))
        XCTAssertLessThan(pixel.red, 0.5)
        XCTAssertGreaterThan(pixel.green, 0.5)
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

    func testThumbnailReturnsNilWhenTheAssetHasNoVideoTrack() async throws {
        let loader = ClipThumbnailLoader()

        // A real audio-only file: track loading succeeds but finds no video track, so
        // the nil comes from the loader's no-video-track guard — not from a decode
        // throw. The card falls back to its placeholder tile; a throw must never reach
        // the view.
        let audioURL = try Self.audioOnlyFileURL()
        // The helper writes the WAV into tmp on every run; clean it up so the test
        // leaves no scratch behind.
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let result = await loader.thumbnail(
            for: makeItem(), in: AVURLAsset(url: audioURL))

        XCTAssertNil(result)
    }

    // MARK: - Helpers

    /// A minimal but structurally valid WAV (44-byte header, zero samples): AVFoundation
    /// parses it as an audio asset, so video-track loading succeeds with no video track.
    private static func audioOnlyFileURL() throws -> URL {
        var header = Data()
        func append(_ string: String) { header.append(contentsOf: string.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        append("RIFF"); appendLE(UInt32(36)); append("WAVE")
        append("fmt "); appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(1)) // mono
        appendLE(UInt32(44_100))
        appendLE(UInt32(88_200)) // byte rate
        appendLE(UInt16(2)) // block align
        appendLE(UInt16(16)) // bits per sample
        append("data"); appendLE(UInt32(0)) // zero samples
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try header.write(to: url)
        return url
    }

    /// Test image split into two distinguishable halves — left red, right green — so a
    /// crop test can prove *which* region was extracted, not just its size. Colors are
    /// built in the same device-RGB space the context uses, so the halves read back as
    /// pure primaries.
    private static func testImage(width: Int, height: Int) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        let halfWidth = width / 2
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: halfWidth, height: height))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: halfWidth, y: 0, width: width - halfWidth, height: height))
        return context.makeImage()
    }

    /// The RGBA bytes of one pixel, read in data order (top row first). The vertical
    /// orientation doesn't matter for the left/right-half assertions below.
    private static func pixel(atX x: Int, y: Int, in image: CGImage) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard image.bitsPerPixel == 32,
              let data = image.dataProvider?.data as Data?
        else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 4 <= data.count else { return nil }
        return (
            red: CGFloat(data[offset]) / 255,
            green: CGFloat(data[offset + 1]) / 255,
            blue: CGFloat(data[offset + 2]) / 255
        )
    }
}
