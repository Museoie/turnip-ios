import CoreGraphics
import XCTest
@testable import Turnip

final class ClipExporterTests: XCTestCase {
    private let landscape = CGSize(width: 1920, height: 1080)

    /// A 90°-rotated track's preferredTransform: landscape-encoded portrait video.
    /// Encoded (0,0) is the displayed top-right, so it discriminates transforms that mix up
    /// encoded and displayed space.
    private let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

    private func assertPoint(
        _ point: CGPoint,
        mapsTo expected: CGPoint,
        by transform: CGAffineTransform,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = point.applying(transform)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.001, "x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.001, "y", file: file, line: line)
    }

    // MARK: - trimmedRange

    func testTrimmedRangeClampsTheWindowToTheAssetDuration() {
        let range = ClipExporter.trimmedRange(
            for: TrickWindow(startTime: 8, endTime: 20), duration: 15)

        XCTAssertEqual(range, 8...15)
    }

    func testTrimmedRangeClampsANegativeStartToZero() {
        let range = ClipExporter.trimmedRange(
            for: TrickWindow(startTime: -1, endTime: 5), duration: 60)

        XCTAssertEqual(range, 0...5)
    }

    func testTrimmedRangeReturnsNilWhenNothingSurvivesTheClamp() {
        // Window entirely past the end of the video.
        XCTAssertNil(ClipExporter.trimmedRange(
            for: TrickWindow(startTime: 70, endTime: 75), duration: 60))
        // Empty window.
        XCTAssertNil(ClipExporter.trimmedRange(
            for: TrickWindow(startTime: 5, endTime: 5), duration: 60))
        // Inverted window.
        XCTAssertNil(ClipExporter.trimmedRange(
            for: TrickWindow(startTime: 10, endTime: 4), duration: 60))
    }

    // MARK: - ClipExportTransform

    func testFullFrameCropWithIdentityTransformKeepsSizeAndOrientation() throws {
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            naturalSize: landscape,
            preferredTransform: .identity))

        XCTAssertEqual(transform.renderSize, landscape)
        // Top-left of the source lands at the top-left of the render frame: the
        // compositor's render space is top-left-origin, so no Y-flip is applied.
        assertPoint(CGPoint(x: 0, y: 0), mapsTo: CGPoint(x: 0, y: 0), by: transform.layerTransform)
        assertPoint(CGPoint(x: 1920, y: 1080), mapsTo: CGPoint(x: 1920, y: 1080), by: transform.layerTransform)
        assertPoint(CGPoint(x: 960, y: 540), mapsTo: CGPoint(x: 960, y: 540), by: transform.layerTransform)
    }

    func testPartialCropTranslatesTheCropToTheRenderOrigin() throws {
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.25, maxY: 0.75),
            naturalSize: landscape,
            preferredTransform: .identity))

        // 960x540 pixels: the crop is not scaled, so the render is exactly the crop's size.
        XCTAssertEqual(transform.renderSize, CGSize(width: 960, height: 540))
        assertPoint(CGPoint(x: 480, y: 270), mapsTo: CGPoint(x: 0, y: 0), by: transform.layerTransform)
        assertPoint(CGPoint(x: 1440, y: 810), mapsTo: CGPoint(x: 960, y: 540), by: transform.layerTransform)
    }

    func testRotatedTrackExportsUpright() throws {
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            naturalSize: landscape,
            preferredTransform: rotate90))

        // The 1920x1080 landscape encoding is really a 1080x1920 portrait video.
        XCTAssertEqual(transform.renderSize, CGSize(width: 1080, height: 1920))
        // Encoded (0,0) is the displayed top-right — no flip on top of the rotation.
        assertPoint(CGPoint(x: 0, y: 0), mapsTo: CGPoint(x: 1080, y: 0), by: transform.layerTransform)
        assertPoint(CGPoint(x: 1920, y: 1080), mapsTo: CGPoint(x: 0, y: 1920), by: transform.layerTransform)
    }

    func testRotatedTrackSubtractsTheCropOriginInDisplayedSpace() throws {
        // The right half of the encoded frame. A transform that subtracts the *encoded*
        // origin from displayed coordinates would land the crop's top-left at x = 1080 - 960
        // instead of 1080, so this case fails on exactly that bug.
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0.5, maxX: 1, minY: 0, maxY: 1),
            naturalSize: landscape,
            preferredTransform: rotate90))

        XCTAssertEqual(transform.renderSize, CGSize(width: 1080, height: 960))
        // Encoded crop corners, mapped through the 90° rotation into displayed space,
        // then translated to the render origin — top-left stays top-left.
        assertPoint(CGPoint(x: 960, y: 0), mapsTo: CGPoint(x: 1080, y: 0), by: transform.layerTransform)
        assertPoint(CGPoint(x: 1920, y: 1080), mapsTo: CGPoint(x: 0, y: 960), by: transform.layerTransform)
        assertPoint(CGPoint(x: 1440, y: 540), mapsTo: CGPoint(x: 540, y: 480), by: transform.layerTransform)
    }

    func testMakeReturnsNilForUnknownSourceSize() {
        XCTAssertNil(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            naturalSize: .zero,
            preferredTransform: .identity))
    }

    func testMakeReturnsNilForADegenerateCropRect() {
        // A zero-width crop (e.g. every confident keypoint on one vertical line) has no
        // frame to render into; the exporter turns this into .invalidCropRect.
        XCTAssertNil(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0.2, maxY: 0.8),
            naturalSize: landscape,
            preferredTransform: .identity))
    }

    func testRenderSizeIsRoundedUpToEvenDimensions() throws {
        // Float keypoint math denormalizes to fractional pixels (here 839.23 wide);
        // H.264 needs integral, even dimensions, so the render rounds to 840x1080.
        // A size that truncates to odd dimensions would fail on this expectation.
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0, maxX: 0.4371, minY: 0, maxY: 1),
            naturalSize: landscape,
            preferredTransform: .identity))

        XCTAssertEqual(transform.renderSize, CGSize(width: 840, height: 1080))
        // The crop's displayed top-left stays pinned to the render origin — the extra
        // pixel pads the right edge rather than shifting the picture.
        assertPoint(CGPoint(x: 0, y: 0), mapsTo: .zero, by: transform.layerTransform)
    }

    // MARK: - removeExistingFile

    func testRemoveExistingFileDeletesAStaleOutput() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try Data("partial".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try ClipExporter.removeExistingFile(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemoveExistingFileToleratesAMissingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        // Must not throw: the first export to a fresh filename hits this path.
        try ClipExporter.removeExistingFile(at: url)
    }
}
