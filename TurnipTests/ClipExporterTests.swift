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

    /// A crop rect overhanging the frame (`CropRectCalculator.fittedInFrame` keeps the
    /// target ratio over fitting inside): the render is the whole crop, overhang included,
    /// and the frame's content lands shifted down by the overhang, so the rows above it
    /// are the black letterbox the editor's fixed marker shows there.
    func testCropOverhangingTheFrameRendersTheWholeCropWithTheFrameOffsetInside() throws {
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: -0.25, maxY: 1.25),
            naturalSize: landscape,
            preferredTransform: .identity))

        // 960 wide, 1.5 × 1080 = 1620 tall: 270 of overhang above and below the frame.
        XCTAssertEqual(transform.renderSize, CGSize(width: 960, height: 1620))
        assertPoint(CGPoint(x: 480, y: 0), mapsTo: CGPoint(x: 0, y: 270), by: transform.layerTransform)
        assertPoint(CGPoint(x: 1440, y: 1080), mapsTo: CGPoint(x: 960, y: 1350), by: transform.layerTransform)
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
        // size maps this to the displayed middle band instead of the
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

    // MARK: - A moving crop

    private let movingPath = CropPath(keyframes: [
        CropKeyframe(time: 2, rect: NormalizedRect(minX: 0.1, maxX: 0.3, minY: 0.2, maxY: 0.8)),
        CropKeyframe(time: 3, rect: NormalizedRect(minX: 0.4, maxX: 0.6, minY: 0.2, maxY: 0.8)),
        CropKeyframe(time: 4, rect: NormalizedRect(minX: 0.7, maxX: 0.9, minY: 0.2, maxY: 0.8))
    ])

    private func staticTransform(at time: TimeInterval) throws -> CGAffineTransform {
        try XCTUnwrap(ClipExportTransform.make(
            cropRect: movingPath.rect(at: time), naturalSize: landscape, preferredTransform: .identity)
        ).layerTransform
    }

    /// The span's start is composition time zero; between it, each keyframe inside it and its
    /// end, the transform ramps from what a static crop on the path's rect would use at one
    /// end to what it would use at the other.
    func testAMovingCropRampsBetweenItsKeyframesInCompositionTime() throws {
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropPath: movingPath, over: 1...5, naturalSize: landscape, preferredTransform: .identity))

        // A path never zooms, so the whole clip renders at the size a static crop on any one of
        // its rects would — computed rather than written out, since 0.2 of 1920 in Float rounds
        // up to the next even pixel.
        let firstRect = try XCTUnwrap(ClipExportTransform.make(
            cropRect: movingPath.keyframes[0].rect, naturalSize: landscape, preferredTransform: .identity))
        XCTAssertEqual(transform.renderSize, firstRect.renderSize)
        let stops: [TimeInterval] = [1, 2, 3, 4, 5]
        XCTAssertEqual(transform.ramps.count, stops.count - 1)
        for (ramp, (earlier, later)) in zip(transform.ramps, zip(stops, stops.dropFirst())) {
            assertRange(ramp.timeRange, start: earlier - 1, end: later - 1)
            XCTAssertEqual(ramp.start, try staticTransform(at: earlier), "from \(earlier)")
            XCTAssertEqual(ramp.end, try staticTransform(at: later), "to \(later)")
        }
        XCTAssertEqual(transform.layerTransform, try staticTransform(at: 1))
    }

    /// A trimmed clip starts and ends between keyframes: its ramps are cut at its own ends, at
    /// the path's rect there, and the keyframes outside it play no part.
    func testAMovingCropCutsItsRampsAtTheSpansEnds() throws {
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropPath: movingPath, over: 2.5...3.5, naturalSize: landscape, preferredTransform: .identity))

        XCTAssertEqual(transform.ramps.count, 2)
        assertRange(transform.ramps[0].timeRange, start: 0, end: 0.5)
        assertRange(transform.ramps[1].timeRange, start: 0.5, end: 1)
        // Halfway between the first two keyframes the crop's left edge is at 0.25 of 1920.
        XCTAssertEqual(transform.layerTransform.tx, -480, accuracy: 0.001)
        XCTAssertEqual(transform.ramps[1].end, try staticTransform(at: 3.5))
    }

    func testAMovingCropIsNilForAnUnknownSourceSize() {
        XCTAssertNil(ClipExportTransform.make(
            cropPath: movingPath, over: 1...5, naturalSize: .zero, preferredTransform: .identity))
    }

    func testAnExportWithoutAPathKeepsTheStaticCrop() throws {
        let still = try XCTUnwrap(ClipExportTransform.make(
            cropRect: NormalizedRect(minX: 0.2, maxX: 0.4, minY: 0, maxY: 1),
            naturalSize: landscape, preferredTransform: .identity))
        let spec = ClipSpec(
            window: TrickWindow(startTime: 1, endTime: 5),
            cropRect: NormalizedRect(minX: 0.2, maxX: 0.4, minY: 0, maxY: 1))

        let transform = try ClipExporter.renderTransform(
            for: spec, staticTransform: still, videoRange: secondsRange(1, 5),
            naturalSize: landscape, preferredTransform: .identity)

        XCTAssertEqual(transform.layerTransform, still.layerTransform)
        XCTAssertTrue(transform.ramps.isEmpty)
    }

    /// The trimmed composition starts where the trimmed video range does, which is where the
    /// ramps have to be timed from — not the trick window's own start.
    func testAnExportWithAPathTimesItsRampsFromTheTrimmedVideoRange() throws {
        let still = try XCTUnwrap(ClipExportTransform.make(
            cropRect: movingPath.keyframes[0].rect, naturalSize: landscape, preferredTransform: .identity))
        let spec = ClipSpec(
            window: TrickWindow(startTime: 1, endTime: 5), cropRect: movingPath.keyframes[0].rect,
            cropPath: movingPath)

        let transform = try ClipExporter.renderTransform(
            for: spec, staticTransform: still, videoRange: secondsRange(1.5, 4.5),
            naturalSize: landscape, preferredTransform: .identity)

        XCTAssertEqual(transform.ramps.count, 4)
        assertRange(transform.ramps[0].timeRange, start: 0, end: 0.5)
        XCTAssertEqual(transform.layerTransform, try staticTransform(at: 1.5))
        assertRange(transform.ramps[3].timeRange, start: 2.5, end: 3)
    }

    /// The ramps have to reach the layer instruction: a composition that dropped them would
    /// still render at the right size and hold the first frame's crop for the whole clip.
    func testTheVideoCompositionCarriesEachRamp() async throws {
        let url = try await TestVideoWriter.writeTestVideo(frameCount: 150, width: 64, height: 36, fps: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        let transform = try XCTUnwrap(ClipExportTransform.make(
            cropPath: movingPath, over: 1...5, naturalSize: CGSize(width: 64, height: 36),
            preferredTransform: .identity))

        let composition = transform.makeVideoComposition(
            for: track, duration: CMTime(seconds: 4, preferredTimescale: 600), frameRate: 30)

        let instruction = try XCTUnwrap(
            composition.instructions.first as? AVMutableVideoCompositionInstruction)
        let layerInstruction = try XCTUnwrap(instruction.layerInstructions.first)
        for expected in transform.ramps {
            let midpoint = CMTimeAdd(expected.timeRange.start, CMTimeMultiplyByRatio(expected.timeRange.duration,
                                                                                    multiplier: 1, divisor: 2))
            var start = CGAffineTransform.identity
            var end = CGAffineTransform.identity
            var range = CMTimeRange(start: .zero, duration: .zero)
            XCTAssertTrue(layerInstruction.getTransformRamp(for: midpoint, start: &start, end: &end, timeRange: &range))
            XCTAssertEqual(start, expected.start)
            XCTAssertEqual(end, expected.end)
            XCTAssertEqual(range, expected.timeRange)
        }
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

    // MARK: - ClipExportError messages

    /// Every case carries its own human-readable message, asserted through
    /// `localizedDescription` — the exact path the save-flow adapters use to flatten
    /// these errors (`ClipSaveError.exportFailed(reason: error.localizedDescription)`).
    /// Without the `LocalizedError` conformance each of these would surface as Swift's
    /// NSError-bridge placeholder ("The operation couldn't be completed.
    /// (Turnip.ClipExportError error N.)").
    func testEachExportErrorCarriesItsOwnMessage() {
        XCTAssertEqual(
            ClipExportError.noVideoTrack.localizedDescription,
            "This video has no video track to export.")
        XCTAssertEqual(
            ClipExportError.invalidTimeRange(
                window: TrickWindow(startTime: 70, endTime: 75)).localizedDescription,
            "This clip's time window is outside the video, so it couldn't be exported.")
        XCTAssertEqual(
            ClipExportError.invalidCropRect(
                window: TrickWindow(startTime: 8, endTime: 20)).localizedDescription,
            "This clip's crop area is invalid, so it couldn't be exported.")
        XCTAssertEqual(
            ClipExportError.exportFailed(reason: "could not create an export session")
                .localizedDescription,
            "Couldn't export this clip. (could not create an export session)")
        XCTAssertEqual(
            ClipExportError.cancelled.localizedDescription,
            "The export was cancelled.")
    }
}
