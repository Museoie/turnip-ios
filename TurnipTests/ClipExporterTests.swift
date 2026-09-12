import AVFoundation
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
        // The right half of the *displayed* (portrait) frame: cropRect is normalized in
        // display orientation, so x in [0.5, 1] is the displayed right half, not the
        // encoded right half. A transform that subtracts the *encoded* origin from
        // displayed coordinates would land the crop's top-left at x = 1080 - 960
        // instead of 0, so this case fails on exactly that bug.
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0.5, maxX: 1, minY: 0, maxY: 1),
            naturalSize: landscape,
            preferredTransform: rotate90))

        // Displayed size is 1080x1920; the crop is the right half: 540x1920.
        XCTAssertEqual(transform.renderSize, CGSize(width: 540, height: 1920))
        // The crop's displayed top-left (540, 0) is encoded (0, 540): it must land at
        // the render origin, and the displayed bottom-right (1080, 1920) — encoded
        // (1920, 0) — at the render frame's far corner.
        assertPoint(CGPoint(x: 0, y: 540), mapsTo: CGPoint(x: 0, y: 0), by: transform.layerTransform)
        assertPoint(CGPoint(x: 1920, y: 0), mapsTo: CGPoint(x: 540, y: 1920), by: transform.layerTransform)
    }

    func testRotatedTrackCropUsesTheDisplayedSize() throws {
        // Athlete in the upper middle of the upright frame: display-normalized rect
        // x in [0.25, 0.75], y in [0.10, 0.60]. Denormalizing against the *encoded*
        // size (the old bug) maps this to the displayed middle band instead of the
        // upper middle; the layer transform then points at the wrong region.
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.10, maxY: 0.60),
            naturalSize: landscape,
            preferredTransform: rotate90))

        // Displayed 1080x1920: crop is 540x960 pixels.
        XCTAssertEqual(transform.renderSize, CGSize(width: 540, height: 960))
        // The crop's displayed top-left (270, 192) is encoded (192, 810): it must land
        // at the render origin. Under the encoded-size bug this encoded point maps to
        // (-162, -288) instead — the athlete would be cropped out.
        assertPoint(CGPoint(x: 192, y: 810), mapsTo: CGPoint(x: 0, y: 0), by: transform.layerTransform)
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
        // Float keypoint math denormalizes to fractional pixels: 838.85 wide, which
        // round-to-nearest would take *down* to 838 and round-up takes to 840. Widening
        // is the only direction that pads rather than clips the pinned crop, so the
        // fixture is chosen to fail against a round-to-nearest implementation.
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0, maxX: 0.4369, minY: 0, maxY: 1),
            naturalSize: landscape,
            preferredTransform: .identity))

        XCTAssertEqual(transform.renderSize, CGSize(width: 840, height: 1080))
        // The crop's displayed top-left stays pinned to the render origin — the extra
        // pixel pads the right edge rather than shifting the picture.
        assertPoint(CGPoint(x: 0, y: 0), mapsTo: .zero, by: transform.layerTransform)
    }

    // MARK: - insertRanges

    /// Builds a CMTimeRange from seconds; the export path uses timescale 600.
    private func secondsRange(_ start: TimeInterval, _ end: TimeInterval) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600))
    }

    private func assertRange(
        _ range: CMTimeRange,
        start: TimeInterval,
        end: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(range.start.seconds, start, accuracy: 0.0001, "start", file: file, line: line)
        XCTAssertEqual(range.end.seconds, end, accuracy: 0.0001, "end", file: file, line: line)
    }

    func testInsertRangesOffsetsAudioToTheVideoStart() throws {
        // Capture ramp-up: the audio track starts 20 ms after the video track. Inserting
        // both tracks at .zero would pin that 20 ms offset into the whole clip, so the
        // audio must land at its offset from the video range's start instead.
        let ranges = try XCTUnwrap(ClipExporter.insertRanges(
            trim: secondsRange(0, 2),
            videoTrack: secondsRange(0, 10),
            audioTrack: secondsRange(0.02, 10)))

        assertRange(ranges.video, start: 0, end: 2)
        assertRange(ranges.audio, start: 0.02, end: 2)
        // The audio's composition-time origin: a source sample at 0.02 lands at 0.02
        // while the video's 0.0 lands at 0.0, so the board-pop stays on its frame.
        XCTAssertEqual(ranges.audioOffset.seconds, 0.02, accuracy: 0.0001)
    }

    func testInsertRangesReturnsNilWhenTheTrimHoldsNoVideo() {
        // A window inside the asset's duration but past the last video sample: the audio
        // track runs on, so intersecting with the trim alone would accept it. The empty
        // video range is deterministic in (window, asset) — the caller reports
        // .invalidTimeRange (skip the clip), not the retryable .exportFailed.
        XCTAssertNil(ClipExporter.insertRanges(
            trim: secondsRange(20, 25),
            videoTrack: secondsRange(0, 10),
            audioTrack: secondsRange(0, 30)))
    }

    func testInsertRangesClampsAudioToTheVideoRange() throws {
        // The audio track outruns the video track: without the subordinate intersection
        // the composition would end with two seconds of audio and no picture.
        let ranges = try XCTUnwrap(ClipExporter.insertRanges(
            trim: secondsRange(0, 10),
            videoTrack: secondsRange(0, 8),
            audioTrack: secondsRange(0, 10)))

        assertRange(ranges.video, start: 0, end: 8)
        assertRange(ranges.audio, start: 0, end: 8)
        XCTAssertEqual(ranges.audioOffset.seconds, 0, accuracy: 0.0001)
    }

    func testInsertRangesWithNoAudioTrackExportsSilent() throws {
        let ranges = try XCTUnwrap(ClipExporter.insertRanges(
            trim: secondsRange(0, 2),
            videoTrack: secondsRange(0, 10),
            audioTrack: nil))

        assertRange(ranges.video, start: 0, end: 2)
        XCTAssertEqual(ranges.audio.duration.seconds, 0, accuracy: 0.0001)
    }

    func testInsertRangesReturnsNilWhenTheTrimMissesTheVideoTrack() {
        XCTAssertNil(ClipExporter.insertRanges(
            trim: secondsRange(0, 2),
            videoTrack: secondsRange(5, 10),
            audioTrack: secondsRange(0, 10)))
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
