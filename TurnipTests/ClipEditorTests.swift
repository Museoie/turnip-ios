import AVFoundation
import CoreGraphics
import XCTest
@testable import Turnip

final class ClipEditorTests: XCTestCase {
    /// 200x100 landscape source; the athlete's x positions below are exactly representable
    /// in Float so the crop assertions don't fight float dust.
    private let naturalSize = CGSize(width: 200, height: 100)
    private let duration: TimeInterval = 60

    /// 40 frames at the fixture's 0.1s interval: the athlete stands at x≈0.3 for the first
    /// 2s, then at x≈0.7 for the next 2s. Trimming across the 2s boundary must move the
    /// crop rect with it.
    private func twoPositionFrames() -> [PoseFrameResult] {
        let early = (0..<20).map { 0.28 + 0.04 * Float($0) / 19 }
        let late = (0..<20).map { 0.68 + 0.04 * Float($0) / 19 }
        return PoseFixture.frames(hipXPositions: early + late)
    }

    private func makeSource(
        window: TrickWindow = TrickWindow(startTime: 2, endTime: 5),
        frames: [PoseFrameResult]
    ) -> ClipEditorSource {
        ClipEditorSource(
            window: window,
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            // AVAsset is abstract; these tests inject media info directly and never load it.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            poseFrames: frames)
    }

    @MainActor
    private func makeViewModel(
        window: TrickWindow = TrickWindow(startTime: 2, endTime: 5),
        frames: [PoseFrameResult]? = nil
    ) -> ClipEditorViewModel {
        let viewModel = ClipEditorViewModel(
            source: makeSource(window: window, frames: frames ?? twoPositionFrames()))
        viewModel.setMediaInfo(
            duration: duration, naturalSize: naturalSize, preferredTransform: .identity)
        return viewModel
    }

    // MARK: - Trimming leaves the framing alone

    /// The framing is what the user last set, and a handle drag is a trim, not a re-crop:
    /// widening the window over the athlete's whole travel must not grow the crop (which
    /// showed as the video shrinking under the fixed marker). Only Auto crop refits.
    @MainActor
    func testTrimmingNeverChangesTheCropRectOrTheAdjustment() {
        let viewModel = makeViewModel(window: TrickWindow(startTime: 2, endTime: 2.5), frames: twoPositionFrames())
        viewModel.applyCropScale(2)
        let cropRect = viewModel.cropRect, adjustment = viewModel.cropAdjustment

        viewModel.trimStart(to: 0)
        viewModel.trimEnd(to: 3.9)

        XCTAssertEqual(viewModel.window, TrickWindow(startTime: 0, endTime: 3.9))
        XCTAssertEqual(viewModel.cropRect, cropRect)
        XCTAssertEqual(viewModel.cropAdjustment, adjustment)
    }

    @MainActor
    func testLoadingMediaInfoLeavesTheCropRectAlone() {
        // The clip opens on the framing it arrived with, even when the window's own
        // frames would fit differently (here, the source's full-frame rect).
        let viewModel = makeViewModel(window: TrickWindow(startTime: 0, endTime: 3.9))

        XCTAssertEqual(viewModel.cropRect, NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
    }

    // MARK: - Auto crop

    /// Auto crop is the one way the framing follows the window: after widening the window
    /// over the athlete's whole travel, the fit frames all of it, and the trimmed-in half
    /// alone when the window is narrowed back.
    @MainActor
    func testAutoCropFitsTheTrimmedWindowsKeypoints() throws {
        // A portrait frame: the athlete's whole travel fits a 9:16 crop inside it, so the
        // fit can hold every keypoint without reaching past the frame.
        let frames = twoPositionFrames()
        let viewModel = ClipEditorViewModel(
            source: makeSource(window: TrickWindow(startTime: 0, endTime: 3.9), frames: frames))
        viewModel.setMediaInfo(
            duration: duration, naturalSize: CGSize(width: 100, height: 200), preferredTransform: .identity)
        let overlay = try XCTUnwrap(viewModel.previewOverlay)

        viewModel.autoCrop()
        let wide = viewModel.cropAdjustment
        viewModel.trimStart(to: 2.0)
        viewModel.autoCrop()
        let narrow = viewModel.cropAdjustment

        // Both fits keep every keypoint in play inside the marker...
        let marker = ClipEditorViewModel.markerBox(around: overlay.cropRect, aspectRatio: 9.0 / 16.0)
        for (window, adjustment) in [(TrickWindow(startTime: 0, endTime: 3.9), wide),
                                     (TrickWindow(startTime: 2, endTime: 3.9), narrow)] {
            let inWindow = frames.filter { $0.timestamp >= window.startTime && $0.timestamp <= window.endTime }
            for point in CropRectCalculator.locatedPoints(in: inWindow) {
                let pixel = CGPoint(x: point.x * overlay.videoSize.width, y: point.y * overlay.videoSize.height)
                let position = markerPosition(of: pixel, cropRect: overlay.cropRect, adjustment: adjustment)
                XCTAssertLessThanOrEqual(abs(position.x), marker.width / 2 + 0.01)
                XCTAssertLessThanOrEqual(abs(position.y), marker.height / 2 + 0.01)
            }
        }
        // ...and the narrower window zooms in: the athlete's late position alone needs
        // less of the frame than the whole travel does.
        XCTAssertGreaterThan(narrow.scale, wide.scale)
        XCTAssertEqual(narrow.rotationRadians, 0)
    }

    @MainActor
    func testAutoCropAtZeroRotationReproducesThePipelinesFraming() {
        // A clip that opens on the pipeline's rect for its window: the fit is that same
        // rect, so a manual pinch and drag go and the adjustment is identity — to within
        // the float dust the pipeline's Float rect carries into the marker's ratio.
        let frames = twoPositionFrames()
        let window = TrickWindow(startTime: 2, endTime: 3.9)
        let pipelineRect = CropRectCalculator().cropRect(
            for: frames.filter { $0.timestamp >= window.startTime && $0.timestamp <= window.endTime },
            renderedPixelSize: naturalSize)
        let viewModel = ClipEditorViewModel(source: ClipEditorSource(
            window: window,
            cropRect: pipelineRect ?? NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            poseFrames: frames))
        viewModel.setMediaInfo(duration: duration, naturalSize: naturalSize, preferredTransform: .identity)
        XCTAssertNotNil(pipelineRect)

        viewModel.applyCropScale(2)
        viewModel.applyCropOffset(CGSize(width: 10, height: 10), previewScale: 1)
        viewModel.autoCrop()

        XCTAssertEqual(viewModel.cropAdjustment.scale, 1, accuracy: 0.00001)
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0)
        XCTAssertEqual(viewModel.cropAdjustment.offset.width, 0, accuracy: 0.001)
        XCTAssertEqual(viewModel.cropAdjustment.offset.height, 0, accuracy: 0.001)
    }

    @MainActor
    func testAutoCropFitsInDisplayedSpaceOnRotatedClips() throws {
        // 90°-rotated track: the encoded 200x100 is really a 100x200 portrait video. The
        // keypoints are measured in displayed space, so the fit's ratio snap must use the
        // displayed size — the encoded naturalSize transposes the dimensions and lands a
        // wrongly-proportioned rect, which the marker (also displayed-space) wouldn't fit.
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 100, ty: 0)
        let frames = twoPositionFrames()
        // Ends past the last frame's 39 × 0.1 s timestamp, which floating point puts a
        // hair beyond 3.9, so the window holds every frame `expected` below is built from.
        let window = TrickWindow(startTime: 0, endTime: 4)
        let viewModel = ClipEditorViewModel(source: makeSource(window: window, frames: frames))
        viewModel.setMediaInfo(duration: duration, naturalSize: naturalSize, preferredTransform: rotate90)
        let overlay = try XCTUnwrap(viewModel.previewOverlay)
        XCTAssertEqual(overlay.videoSize, CGSize(width: 100, height: 200))

        viewModel.autoCrop()

        // The fit is the pipeline's rect for these frames in displayed space, expressed
        // on the full-frame anchor: the marker's width over the rect's is the scale.
        let expected = try XCTUnwrap(CropRectCalculator().cropRect(for: frames, renderedPixelSize: overlay.videoSize))
        let marker = ClipEditorViewModel.markerBox(around: overlay.cropRect, aspectRatio: 9.0 / 16.0)
        let expectedScale = marker.width / expected.denormalized(in: overlay.videoSize).width
        XCTAssertEqual(viewModel.cropAdjustment.scale, expectedScale, accuracy: 0.0001)
    }

    func testMarkerBoxIsTheSmallestTargetRatioRectAroundTheCropRect() {
        // A 9:16 rect is its own marker box; a 1:2 full frame gets a wider one, centered.
        let own = CGRect(x: 10, y: 20, width: 90, height: 160)
        XCTAssertEqual(ClipEditorViewModel.markerBox(around: own, aspectRatio: 9.0 / 16.0), own)

        let tall = ClipEditorViewModel.markerBox(
            around: CGRect(x: 0, y: 0, width: 100, height: 200), aspectRatio: 9.0 / 16.0)
        XCTAssertEqual(tall.width, 112.5, accuracy: 0.0001)
        XCTAssertEqual(tall.height, 200, accuracy: 0.0001)
        XCTAssertEqual(tall.midX, 50, accuracy: 0.0001)

        let wide = ClipEditorViewModel.markerBox(
            around: CGRect(x: 0, y: 0, width: 200, height: 100), aspectRatio: 9.0 / 16.0)
        XCTAssertEqual(wide.width, 200, accuracy: 0.0001)
        XCTAssertEqual(wide.height, 200 * 16 / 9, accuracy: 0.0001)
        XCTAssertEqual(wide.midY, 50, accuracy: 0.0001)
    }

    // MARK: - Trim clamping

    @MainActor
    func testTrimStartStopsAtEndMinusMinimumDuration() {
        let viewModel = makeViewModel(window: TrickWindow(startTime: 2, endTime: 5))

        viewModel.trimStart(to: 4.9)

        XCTAssertEqual(viewModel.window.startTime, 4.5, accuracy: 0.0001)
        XCTAssertEqual(viewModel.window.endTime, 5, accuracy: 0.0001)
    }

    @MainActor
    func testTrimStartClampsToZero() {
        let viewModel = makeViewModel()

        viewModel.trimStart(to: -5)

        XCTAssertEqual(viewModel.window.startTime, 0, accuracy: 0.0001)
    }

    @MainActor
    func testTrimEndStopsAtStartPlusMinimumDuration() {
        let viewModel = makeViewModel(window: TrickWindow(startTime: 2, endTime: 5))

        viewModel.trimEnd(to: 2.1)

        XCTAssertEqual(viewModel.window.endTime, 2.5, accuracy: 0.0001)
        XCTAssertEqual(viewModel.window.startTime, 2, accuracy: 0.0001)
    }

    @MainActor
    func testTrimEndClampsToDuration() {
        let viewModel = makeViewModel()

        viewModel.trimEnd(to: 600)

        XCTAssertEqual(viewModel.window.endTime, duration, accuracy: 0.0001)
    }

    @MainActor
    func testTrimmingBeforeMediaInfoLoadsIsANoOp() {
        // Without the duration there is nothing to clamp against; the handles wait.
        let viewModel = ClipEditorViewModel(source: makeSource(frames: twoPositionFrames()))

        viewModel.trimStart(to: 3)
        viewModel.trimEnd(to: 4)

        XCTAssertEqual(viewModel.window.startTime, 2, accuracy: 0.0001)
        XCTAssertEqual(viewModel.window.endTime, 5, accuracy: 0.0001)
    }

    @MainActor
    func testDetectedWindowOvershootingTheDurationIsReclampedOnLoad() {
        // The detector's trailing buffer can push endTime past the asset; the editor
        // re-clamps on load so the preview loop can't stall past the last frame.
        let viewModel = ClipEditorViewModel(source: makeSource(
            window: TrickWindow(startTime: 58, endTime: 65), frames: twoPositionFrames()))
        viewModel.setMediaInfo(
            duration: duration, naturalSize: naturalSize, preferredTransform: .identity)

        XCTAssertEqual(viewModel.window.endTime, 60, accuracy: 0.0001)
        XCTAssertEqual(viewModel.window.startTime, 58, accuracy: 0.0001)
    }

    func testClampedWindowKeepsMinimumDuration() {
        let clamped = ClipEditorViewModel.clamped(
            window: TrickWindow(startTime: 58, endTime: 65), to: 60)

        XCTAssertEqual(clamped.startTime, 58, accuracy: 0.0001)
        XCTAssertEqual(clamped.endTime, 60, accuracy: 0.0001)
    }

    // MARK: - Preview loop

    /// A detected window's trailing buffer routinely ends at the asset's end. Playing the
    /// item out pauses the player on its own, and the loop has to restart it — otherwise
    /// the preview stops on the clip's last frame instead of looping.
    @MainActor
    func testPreviewKeepsLoopingWhenTheWindowEndsAtTheAssetsEnd() async throws {
        let url = try await HorizonVideoFixture.write(tilt: HorizonVideoFixture.tilt, width: 160, height: 90)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let viewModel = ClipEditorViewModel(source: ClipEditorSource(
            window: TrickWindow(startTime: 0.4, endTime: 1),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            asset: AVURLAsset(url: url),
            poseFrames: []))
        addTeardownBlock { viewModel.teardown() }

        await viewModel.prepare()
        XCTAssertTrue(viewModel.isPlaying)
        // Four times the window: the item has played out at least once by now.
        try await Task.sleep(for: .seconds(2.5))

        XCTAssertGreaterThan(viewModel.player.rate, 0, "the preview stopped instead of looping")
        XCTAssertLessThan(viewModel.currentTime, 1, "the preview is parked on the last frame")
        XCTAssertTrue(viewModel.isPlaying)
    }

    func testLoopBackFiresAtWindowEndDuringPlayback() {
        let window = TrickWindow(startTime: 2, endTime: 6)

        // The epsilon keeps the last frame from flashing past the end handle before the
        // loop-back seek lands.
        XCTAssertTrue(ClipEditorViewModel.shouldLoopBack(at: 6.0, window: window, isTrimming: false))
        XCTAssertTrue(ClipEditorViewModel.shouldLoopBack(at: 5.96, window: window, isTrimming: false))
        XCTAssertFalse(ClipEditorViewModel.shouldLoopBack(at: 5.0, window: window, isTrimming: false))
    }

    func testLoopBackSuppressedWhileTrimming() {
        // Dragging the end handle seeks exactly to the new end: the periodic time observer
        // fires on that jump, and without the guard it would read as the loop point and
        // bounce the preview back to the window start mid-drag.
        let window = TrickWindow(startTime: 2, endTime: 6)

        XCTAssertFalse(ClipEditorViewModel.shouldLoopBack(at: 6.0, window: window, isTrimming: true))
        XCTAssertFalse(ClipEditorViewModel.shouldLoopBack(at: 5.96, window: window, isTrimming: true))
    }

    @MainActor
    func testTrimEndSetsTheTrimmingLatch() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isTrimming)

        // 5.5 is inside [start + 0.5, duration] and differs from the current end (5).
        viewModel.trimEnd(to: 5.5)
        XCTAssertTrue(viewModel.isTrimming)
    }

    @MainActor
    func testTrimStartSetsTheTrimmingLatch() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isTrimming)

        viewModel.trimStart(to: 3.0)
        XCTAssertTrue(viewModel.isTrimming)
    }

    @MainActor
    func testFinishTrimClearsTheTrimmingLatch() {
        let viewModel = makeViewModel()

        viewModel.trimEnd(to: 5.5)
        XCTAssertTrue(viewModel.isTrimming)

        viewModel.finishTrim()
        XCTAssertFalse(viewModel.isTrimming)
    }

    @MainActor
    func testTeardownClearsTheTrimmingLatch() {
        // A cancelled drag never fires the gesture's `onEnded`, so `finishTrim` never
        // runs; the latch must not survive the view going away.
        let viewModel = makeViewModel()

        viewModel.trimEnd(to: 5.5)
        XCTAssertTrue(viewModel.isTrimming)

        viewModel.teardown()
        XCTAssertFalse(viewModel.isTrimming)
    }

    // MARK: - Crop adjustment

    @MainActor
    func testApplyCropScaleMultipliesOntoTheCommittedScale() {
        let viewModel = makeViewModel()

        viewModel.applyCropScale(2)
        viewModel.applyCropScale(1.5)

        XCTAssertEqual(viewModel.cropAdjustment.scale, 3, accuracy: 0.0001)
    }

    @MainActor
    func testApplyCropScaleClampsToASaneRange() {
        let viewModel = makeViewModel()

        viewModel.applyCropScale(0.001)
        XCTAssertEqual(viewModel.cropAdjustment.scale, 0.2, accuracy: 0.0001)

        viewModel.applyCropScale(1000)
        XCTAssertEqual(viewModel.cropAdjustment.scale, 8, accuracy: 0.0001)
    }

    @MainActor
    func testApplyCropRotationAccumulates() {
        let viewModel = makeViewModel()

        viewModel.applyCropRotation(.pi / 4)
        viewModel.applyCropRotation(.pi / 4)

        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, .pi / 2, accuracy: 0.0001)
    }

    @MainActor
    func testApplyCropOffsetAccumulates() {
        let viewModel = makeViewModel()

        viewModel.applyCropOffset(CGSize(width: 10, height: -4), previewScale: 1)
        viewModel.applyCropOffset(CGSize(width: 5, height: 1), previewScale: 1)

        XCTAssertEqual(viewModel.cropAdjustment.offset, CGSize(width: 15, height: -3))
    }

    /// `previewScale` is on-screen points per displayed pixel — a source video's displayed
    /// size is almost always many times the preview's on-screen point size, so dividing by
    /// a realistic sub-1 scale must MAGNIFY the committed offset, not pass it through
    /// unconverted. A fixture using `previewScale: 1` (as the accumulation test above does)
    /// can't tell a correct conversion from a dropped one, since both produce the same
    /// number when the scale is 1.
    @MainActor
    func testApplyCropOffsetConvertsScreenPointsToDisplayedPixels() {
        let viewModel = makeViewModel()

        // A 380pt-wide preview of a 1900px-displayed video: 0.2 points per pixel.
        viewModel.applyCropOffset(CGSize(width: 38, height: -19), previewScale: 0.2)

        XCTAssertEqual(viewModel.cropAdjustment.offset, CGSize(width: 190, height: -95))
    }

    /// Keypoints at the corners of a box in the middle of a portrait frame, small enough
    /// that its fit at a modest turn still lies inside the frame.
    private func centeredBoxFrames() -> [PoseFrameResult] {
        [
            PoseFixture.frame(index: 20, hip: (x: 0.65, y: 0.7), upperBody: (x: 0.35, y: 0.3)),
            PoseFixture.frame(index: 21, hip: (x: 0.35, y: 0.7), upperBody: (x: 0.65, y: 0.3))
        ]
    }

    /// The video point a position relative to the marker's center shows, under
    /// `adjustment`: the inverse of `markerPosition`.
    private func videoPoint(
        atMarkerPosition position: CGPoint, cropRect: CGRect, adjustment: CropAdjustment
    ) -> CGPoint {
        let unscaled = CGPoint(
            x: (position.x - adjustment.offset.width) / adjustment.scale,
            y: (position.y - adjustment.offset.height) / adjustment.scale)
        let unturned = unscaled.applying(CGAffineTransform(rotationAngle: -adjustment.rotationRadians))
        return CGPoint(x: unturned.x + cropRect.midX, y: unturned.y + cropRect.midY)
    }

    /// Asserts the marker shows video in every part of it: its four corners map to points
    /// inside the frame.
    private func assertMarkerInsideTheVideo(
        overlay: (videoSize: CGSize, cropRect: CGRect), adjustment: CropAdjustment,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let marker = ClipEditorViewModel.markerBox(around: overlay.cropRect, aspectRatio: 9.0 / 16.0)
        for (signX, signY) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            let corner = CGPoint(x: signX * marker.width / 2, y: signY * marker.height / 2)
            let shown = videoPoint(atMarkerPosition: corner, cropRect: overlay.cropRect, adjustment: adjustment)
            XCTAssertGreaterThanOrEqual(
                shown.x, -0.01, "corner \(corner) shows past the left edge", file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                shown.y, -0.01, "corner \(corner) shows past the top edge", file: file, line: line)
            XCTAssertLessThanOrEqual(
                shown.x, overlay.videoSize.width + 0.01, "corner \(corner) shows past the right edge",
                file: file, line: line)
            XCTAssertLessThanOrEqual(
                shown.y, overlay.videoSize.height + 0.01, "corner \(corner) shows past the bottom edge",
                file: file, line: line)
        }
    }

    /// Where a displayed-pixel keypoint lands relative to the marker's center under
    /// `adjustment` — the editor's and the export's shared mapping: scale and rotation
    /// about the crop center, then the offset in screen space.
    private func markerPosition(
        of point: CGPoint, cropRect: CGRect, adjustment: CropAdjustment
    ) -> CGPoint {
        let turned = CGPoint(x: point.x - cropRect.midX, y: point.y - cropRect.midY)
            .applying(CGAffineTransform(rotationAngle: adjustment.rotationRadians))
        return CGPoint(
            x: turned.x * adjustment.scale + adjustment.offset.width,
            y: turned.y * adjustment.scale + adjustment.offset.height)
    }

    @MainActor
    func testAutoCropKeepsEveryKeypointInsideTheMarkerAtTheCurrentRotation() throws {
        let frames = centeredBoxFrames()
        let viewModel = ClipEditorViewModel(
            source: makeSource(window: TrickWindow(startTime: 2, endTime: 2.3), frames: frames))
        viewModel.setMediaInfo(
            duration: duration, naturalSize: CGSize(width: 100, height: 200), preferredTransform: .identity)
        let rotation = Double.pi / 18
        viewModel.applyCropRotation(rotation)
        // Zoomed in by hand: the keypoints sit outside the marker, so the fit has
        // something to do.
        viewModel.applyCropScale(3)
        let overlay = try XCTUnwrap(viewModel.previewOverlay)
        let keypoints = CropRectCalculator.locatedPoints(in: frames).map {
            CGPoint(x: $0.x * overlay.videoSize.width, y: $0.y * overlay.videoSize.height)
        }
        let marker = ClipEditorViewModel.markerBox(around: overlay.cropRect, aspectRatio: 9.0 / 16.0)
        let halfWidth = marker.width / 2, halfHeight = marker.height / 2
        XCTAssertTrue(keypoints.contains { point in
            let position = markerPosition(
                of: point, cropRect: overlay.cropRect, adjustment: viewModel.cropAdjustment)
            return abs(position.x) > halfWidth || abs(position.y) > halfHeight
        })

        viewModel.autoCrop()

        let adjustment = viewModel.cropAdjustment
        XCTAssertEqual(adjustment.rotationRadians, rotation, accuracy: 0.0001)
        for point in keypoints {
            let position = markerPosition(of: point, cropRect: overlay.cropRect, adjustment: adjustment)
            XCTAssertLessThanOrEqual(abs(position.x), halfWidth + 0.01, "\(point) left the marker")
            XCTAssertLessThanOrEqual(abs(position.y), halfHeight + 0.01, "\(point) left the marker")
        }
        assertMarkerInsideTheVideo(overlay: overlay, adjustment: adjustment)
    }

    /// The whole crop shows video: on a landscape clip whose athlete spans most of the
    /// width, a 9:16 crop around all of it would reach past the top and bottom of the
    /// frame, so the fit zooms to the frame's height instead of letterboxing.
    @MainActor
    func testAutoCropKeepsTheMarkerInsideTheVideo() throws {
        let viewModel = makeViewModel(window: TrickWindow(startTime: 0, endTime: 4), frames: twoPositionFrames())
        let overlay = try XCTUnwrap(viewModel.previewOverlay)
        XCTAssertEqual(overlay.videoSize, CGSize(width: 200, height: 100))

        viewModel.autoCrop()

        assertMarkerInsideTheVideo(overlay: overlay, adjustment: viewModel.cropAdjustment)
        // Zoomed in: the crop's footprint is the frame's full height, a 56.25-wide box
        // shown in the marker — which, around this landscape full-frame anchor, is the
        // anchor's 200 width tall enough for 9:16.
        XCTAssertEqual(viewModel.cropAdjustment.scale, 200 / 56.25, accuracy: 0.0001)
    }

    @MainActor
    func testAutoCropKeepsTheMarkerInsideTheVideoWhenRotated() throws {
        let viewModel = makeViewModel(window: TrickWindow(startTime: 0, endTime: 4), frames: twoPositionFrames())
        viewModel.applyCropRotation(.pi / 9)
        let overlay = try XCTUnwrap(viewModel.previewOverlay)

        viewModel.autoCrop()

        assertMarkerInsideTheVideo(overlay: overlay, adjustment: viewModel.cropAdjustment)
    }

    // MARK: - Containment

    func testContainedBoxInsideTheFrameIsUnchanged() {
        let box = CGRect(x: -20, y: -40, width: 45, height: 80)
        let contained = ClipEditorViewModel.containedInFrame(
            box, frameSize: CGSize(width: 1080, height: 1920), cropCenter: CGPoint(x: 540, y: 960), rotationRadians: 0)

        XCTAssertEqual(contained, box)
    }

    func testContainedBoxPastAnEdgeSlidesBackByItsOverhang() {
        // Crop center at (100, 100) in a 200x100 frame: a box reaching x 130 in the turned
        // space shows the frame's right edge at x 100. It slides left by 30 and keeps its size.
        let box = CGRect(x: 80, y: -20, width: 50, height: 40)
        let contained = ClipEditorViewModel.containedInFrame(
            box, frameSize: CGSize(width: 200, height: 100), cropCenter: CGPoint(x: 100, y: 50), rotationRadians: 0)

        XCTAssertEqual(contained.maxX, 100, accuracy: 0.0001)
        XCTAssertEqual(contained.size, box.size)
        XCTAssertEqual(contained.midY, box.midY, accuracy: 0.0001)
    }

    func testContainedBoxTallerThanTheFrameShrinksToItAtItsOwnRatio() {
        let box = CGRect(x: -30, y: -80, width: 60, height: 160)
        let contained = ClipEditorViewModel.containedInFrame(
            box, frameSize: CGSize(width: 200, height: 100), cropCenter: CGPoint(x: 100, y: 50), rotationRadians: 0)

        XCTAssertEqual(contained.height, 100, accuracy: 0.0001)
        XCTAssertEqual(contained.width, 37.5, accuracy: 0.0001)
        XCTAssertEqual(contained.midY, 0, accuracy: 0.0001)
    }

    func testContainedBoxFitsTheTurnedFrame() {
        // A 200x100 frame turned a quarter turn about its center is 100 wide and 200 tall
        // in the turned space: a 60x160 box fits it whole, where it couldn't unturned.
        let box = CGRect(x: -30, y: -80, width: 60, height: 160)
        let contained = ClipEditorViewModel.containedInFrame(
            box, frameSize: CGSize(width: 200, height: 100), cropCenter: CGPoint(x: 100, y: 50),
            rotationRadians: .pi / 2)

        XCTAssertEqual(contained.size.width, 60, accuracy: 0.0001)
        XCTAssertEqual(contained.size.height, 160, accuracy: 0.0001)
    }

    func testContainedBoxCornersLieInsideAnObliquelyTurnedFrame() {
        let frame = CGSize(width: 200, height: 100), center = CGPoint(x: 60, y: 30), rotation = 0.5
        let box = CGRect(x: 50, y: 10, width: 90, height: 160)
        let contained = ClipEditorViewModel.containedInFrame(
            box, frameSize: frame, cropCenter: center, rotationRadians: rotation)

        XCTAssertEqual(contained.width / contained.height, box.width / box.height, accuracy: 0.0001)
        let unturn = CGAffineTransform(rotationAngle: -rotation)
        for corner in [CGPoint(x: contained.minX, y: contained.minY), CGPoint(x: contained.maxX, y: contained.minY),
                       CGPoint(x: contained.minX, y: contained.maxY), CGPoint(x: contained.maxX, y: contained.maxY)] {
            let shown = corner.applying(unturn)
            XCTAssertGreaterThanOrEqual(shown.x + center.x, -0.01)
            XCTAssertGreaterThanOrEqual(shown.y + center.y, -0.01)
            XCTAssertLessThanOrEqual(shown.x + center.x, frame.width + 0.01)
            XCTAssertLessThanOrEqual(shown.y + center.y, frame.height + 0.01)
        }
    }

    @MainActor
    func testAutoCropWithNoKeypointsInTheWindowLeavesTheAdjustmentAlone() {
        // No frames fall in this window: there is nothing to frame, and a fit to nothing
        // must not stomp the adjustment.
        let viewModel = makeViewModel(window: TrickWindow(startTime: 10, endTime: 13))

        viewModel.applyCropScale(2)
        viewModel.autoCrop()

        XCTAssertEqual(viewModel.cropAdjustment.scale, 2, accuracy: 0.0001)
    }

    @MainActor
    func testAutoCropBeforeMediaInfoLoadsIsANoOp() {
        let viewModel = ClipEditorViewModel(source: makeSource(frames: twoPositionFrames()))

        viewModel.applyCropScale(2)
        viewModel.autoCrop()

        XCTAssertEqual(viewModel.cropAdjustment.scale, 2, accuracy: 0.0001)
    }

    func testCalculatorKeepsAPointPastTheFrameEdgeWhenNotSlidIntoFrame() throws {
        // Auto crop's reason for skipping the calculator's slide: in a turned space the
        // frame isn't `[0, 1]`, so the editor contains the rect itself, and the calculator
        // must hand it the unslid rect around every point.
        let calculator = CropRectCalculator()
        let points = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1.05, y: 0.6)]
        let size = CGSize(width: 200, height: 100)

        let slid = try XCTUnwrap(calculator.cropRect(around: points, renderedPixelSize: size))
        let unslid = try XCTUnwrap(
            calculator.cropRect(around: points, renderedPixelSize: size, slidIntoFrame: false))

        // Slid, the rect is brought inside the frame (shrunk, here, since 9:16 on this box
        // is taller than the frame); unslid, it still reaches the point past the edge.
        XCTAssertLessThanOrEqual(slid.maxX, 1)
        XCTAssertGreaterThanOrEqual(unslid.maxX, 1.05)
        XCTAssertGreaterThan(unslid.width, slid.width)
    }

    // MARK: - Auto rotate

    /// A view model over a one-second clip whose horizon tilts `HorizonVideoFixture.tilt`
    /// clockwise, with media info loaded so Auto rotate has a window to sample. The movie
    /// file goes with the test's teardown.
    @MainActor
    private func makeHorizonViewModel() async throws -> ClipEditorViewModel {
        let url = try await HorizonVideoFixture.write(tilt: HorizonVideoFixture.tilt, width: 320, height: 180)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let viewModel = ClipEditorViewModel(source: ClipEditorSource(
            window: TrickWindow(startTime: 0, endTime: 1),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            asset: AVURLAsset(url: url),
            poseFrames: []))
        viewModel.setMediaInfo(
            duration: 1, naturalSize: CGSize(width: 320, height: 180), preferredTransform: .identity)
        return viewModel
    }

    @MainActor
    func testAutoRotateBeforeMediaInfoLoadsIsANoOp() {
        let viewModel = ClipEditorViewModel(source: makeSource(frames: []))

        viewModel.autoRotate()

        XCTAssertFalse(viewModel.isDetectingHorizon)
    }

    @MainActor
    func testTeardownCancelsADetectionInFlight() async throws {
        let viewModel = try await makeHorizonViewModel()

        viewModel.autoRotate()
        XCTAssertTrue(viewModel.isDetectingHorizon)
        viewModel.teardown()

        XCTAssertFalse(viewModel.isDetectingHorizon)
        // A cancelled detection must not land late: give it the time it would have taken.
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0)
        XCTAssertFalse(viewModel.isShowingNoHorizonNotice)
    }

    @MainActor
    func testAutoRotateLevelsTheWindowsHorizon() async throws {
        // A clip whose horizon tilts clockwise on screen: the button must turn the video
        // counterclockwise by the same angle, replacing (not adding to) the rotation in place.
        let viewModel = try await makeHorizonViewModel()
        viewModel.applyCropRotation(1)
        viewModel.applyCropScale(2)

        viewModel.autoRotate()
        XCTAssertTrue(viewModel.isDetectingHorizon)
        let deadline = Date().addingTimeInterval(20)
        while viewModel.isDetectingHorizon, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(viewModel.isDetectingHorizon)
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, -HorizonVideoFixture.tilt, accuracy: 0.03)
        // The fit only touches the rotation.
        XCTAssertEqual(viewModel.cropAdjustment.scale, 2, accuracy: 0.0001)
        XCTAssertFalse(viewModel.isShowingNoHorizonNotice)
    }

    // MARK: - Auto fits toggle to resets

    /// A view model whose Auto rotate answers at once with `rotation` (nil: nothing to
    /// level by), with media info loaded so the button is live.
    @MainActor
    private func makeLevelingViewModel(rotation: Double?) -> ClipEditorViewModel {
        let viewModel = ClipEditorViewModel(
            source: makeSource(window: TrickWindow(startTime: 0, endTime: 3.9), frames: twoPositionFrames()),
            levelingRotation: { _, _ in rotation })
        viewModel.setMediaInfo(
            duration: duration, naturalSize: CGSize(width: 100, height: 200), preferredTransform: .identity)
        return viewModel
    }

    @MainActor
    private func autoRotateAndWait(_ viewModel: ClipEditorViewModel) async throws {
        viewModel.autoRotate()
        let deadline = Date().addingTimeInterval(5)
        while viewModel.isDetectingHorizon, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(viewModel.isDetectingHorizon)
    }

    /// A clip detected in the middle of a portrait frame, with media info loaded and a
    /// leveler that answers at once, so both fits and both resets are live.
    @MainActor
    private func makeDetectedCropViewModel() -> ClipEditorViewModel {
        let viewModel = ClipEditorViewModel(
            source: ClipEditorSource(
                window: TrickWindow(startTime: 0, endTime: 3.9),
                cropRect: NormalizedRect(minX: 0.3, maxX: 0.7, minY: 0.2, maxY: 0.6),
                asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                poseFrames: twoPositionFrames()),
            levelingRotation: { _, _ in 0.25 })
        viewModel.setMediaInfo(
            duration: duration, naturalSize: CGSize(width: 100, height: 200), preferredTransform: .identity)
        return viewModel
    }

    /// Reset crop shows the whole source video — the full frame's marker-ratio box landing
    /// exactly on the marker, the way a clip added by hand opens — not the detected crop
    /// and not whatever pinch or drag preceded the Auto tap.
    @MainActor
    func testResetCropShowsTheWholeSourceVideo() throws {
        let viewModel = makeDetectedCropViewModel()
        viewModel.applyCropScale(2)
        viewModel.applyCropOffset(CGSize(width: 10, height: 5), previewScale: 1)
        XCTAssertFalse(viewModel.isAutoCropApplied)
        viewModel.autoCrop()
        XCTAssertTrue(viewModel.isAutoCropApplied)

        viewModel.resetCrop()

        XCTAssertFalse(viewModel.isAutoCropApplied)
        let overlay = try XCTUnwrap(viewModel.previewOverlay)
        let marker = ClipEditorViewModel.markerBox(around: overlay.cropRect, aspectRatio: 9.0 / 16.0)
        let fullFrame = ClipEditorViewModel.markerBox(
            around: CGRect(origin: .zero, size: overlay.videoSize), aspectRatio: 9.0 / 16.0)
        // Each corner of the full frame's box lands on the matching corner of the marker.
        for (signX, signY) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            let corner = CGPoint(
                x: fullFrame.midX + signX * fullFrame.width / 2, y: fullFrame.midY + signY * fullFrame.height / 2)
            let shown = markerPosition(of: corner, cropRect: overlay.cropRect, adjustment: viewModel.cropAdjustment)
            XCTAssertEqual(shown.x, signX * marker.width / 2, accuracy: 0.01, "corner \(corner)")
            XCTAssertEqual(shown.y, signY * marker.height / 2, accuracy: 0.01, "corner \(corner)")
        }
    }

    /// Reset crop leaves the rotation alone, as Auto crop did: the turned full frame is
    /// centered on the marker at the same turn.
    @MainActor
    func testResetCropKeepsTheRotation() throws {
        let viewModel = makeDetectedCropViewModel()
        viewModel.applyCropRotation(0.3)
        viewModel.autoCrop()
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0.3, accuracy: 1e-9)

        viewModel.resetCrop()

        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0.3, accuracy: 1e-9)
        let overlay = try XCTUnwrap(viewModel.previewOverlay)
        let frameCenter = CGPoint(x: overlay.videoSize.width / 2, y: overlay.videoSize.height / 2)
        let shown = markerPosition(of: frameCenter, cropRect: overlay.cropRect, adjustment: viewModel.cropAdjustment)
        XCTAssertEqual(shown.x, 0, accuracy: 0.01)
        XCTAssertEqual(shown.y, 0, accuracy: 0.01)
    }

    /// A clip that opened on the full frame is already showing the whole video: its reset is
    /// the identity framing.
    @MainActor
    func testResetCropOnAFullFrameClipIsTheIdentity() {
        let viewModel = makeLevelingViewModel(rotation: nil)
        viewModel.applyCropScale(2)
        viewModel.autoCrop()

        viewModel.resetCrop()

        XCTAssertEqual(viewModel.cropAdjustment.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(viewModel.cropAdjustment.offset, .zero)
    }

    /// A clip without pose analysis (added by hand) has nothing for Auto crop to fit: it
    /// offers Reset crop alone, which has something to do only once a pinch or drag has
    /// moved the framing off the whole source video, and the rotation alone never counts.
    @MainActor
    func testAClipWithoutPoseFramesOffersResetCropAlone() {
        let viewModel = makeViewModel(frames: [])
        XCTAssertFalse(viewModel.supportsAutoCrop)
        XCTAssertFalse(viewModel.isCropAdjusted)

        viewModel.autoCrop()
        XCTAssertFalse(viewModel.isAutoCropApplied)
        XCTAssertEqual(viewModel.cropAdjustment, .identity)

        viewModel.applyCropRotation(0.3)
        XCTAssertFalse(viewModel.isCropAdjusted, "the rotation is Reset rotate's, not Reset crop's")

        viewModel.applyCropScale(2)
        viewModel.applyCropOffset(CGSize(width: 10, height: 5), previewScale: 1)
        XCTAssertTrue(viewModel.isCropAdjusted)

        viewModel.resetCrop()

        XCTAssertFalse(viewModel.isCropAdjusted)
        XCTAssertEqual(viewModel.cropAdjustment.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(viewModel.cropAdjustment.offset, .zero)
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0.3, accuracy: 1e-9)
    }

    /// A clip with pose analysis keeps its Auto crop, and its framing counts as adjusted
    /// both after a gesture and after Auto crop's own fit moves it off the whole frame.
    @MainActor
    func testAClipWithPoseFramesSupportsAutoCrop() {
        let viewModel = makeDetectedCropViewModel()
        XCTAssertTrue(viewModel.supportsAutoCrop)
        XCTAssertTrue(viewModel.isCropAdjusted, "a detected crop is not the whole frame")

        viewModel.resetCrop()
        XCTAssertFalse(viewModel.isCropAdjusted)

        viewModel.autoCrop()
        XCTAssertTrue(viewModel.isAutoCropApplied)
        XCTAssertTrue(viewModel.isCropAdjusted)
    }

    /// Reset rotate returns the video to its original, unrotated orientation, not to the
    /// rotation the fingers had set before the Auto tap.
    @MainActor
    func testResetRotateReturnsToTheOriginalOrientation() async throws {
        let viewModel = makeLevelingViewModel(rotation: 0.25)
        viewModel.applyCropRotation(1)
        viewModel.applyCropScale(2)

        try await autoRotateAndWait(viewModel)

        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0.25, accuracy: 1e-9)
        XCTAssertTrue(viewModel.isAutoRotateApplied)
        XCTAssertFalse(viewModel.isAutoCropApplied)

        viewModel.resetRotate()

        XCTAssertFalse(viewModel.isAutoRotateApplied)
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0, accuracy: 1e-9)
        // The reset only touches the rotation, as the fit did.
        XCTAssertEqual(viewModel.cropAdjustment.scale, 2, accuracy: 1e-9)
    }

    /// The two resets are independent: returning one to the original leaves the other's
    /// result and its button alone.
    @MainActor
    func testResetCropAndResetRotateAreIndependent() async throws {
        let viewModel = makeLevelingViewModel(rotation: 0.25)
        viewModel.autoCrop()
        try await autoRotateAndWait(viewModel)
        XCTAssertTrue(viewModel.isAutoCropApplied)
        XCTAssertTrue(viewModel.isAutoRotateApplied)
        let fitted = viewModel.cropAdjustment

        viewModel.resetCrop()

        XCTAssertFalse(viewModel.isAutoCropApplied)
        XCTAssertTrue(viewModel.isAutoRotateApplied)
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, fitted.rotationRadians, accuracy: 1e-9)
        XCTAssertEqual(viewModel.cropAdjustment.scale, 1, accuracy: 1e-9)

        viewModel.resetRotate()

        XCTAssertFalse(viewModel.isAutoRotateApplied)
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0, accuracy: 1e-9)
    }

    /// A manual pinch, turn or drag takes over from both fits at once, so both buttons go
    /// back to offering their fit; a gesture that changed nothing is not an edit.
    @MainActor
    func testAManualGestureReturnsBothButtonsToAuto() async throws {
        let viewModel = makeLevelingViewModel(rotation: 0.25)
        viewModel.autoCrop()
        try await autoRotateAndWait(viewModel)

        viewModel.applyCropScale(1)
        viewModel.applyCropRotation(0)
        viewModel.applyCropOffset(.zero, previewScale: 1)
        XCTAssertTrue(viewModel.isAutoCropApplied, "a no-op pinch is not an edit")
        XCTAssertTrue(viewModel.isAutoRotateApplied)

        viewModel.applyCropOffset(CGSize(width: 1, height: 0), previewScale: 1)
        XCTAssertFalse(viewModel.isAutoCropApplied)
        XCTAssertFalse(viewModel.isAutoRotateApplied)

        viewModel.autoCrop()
        viewModel.applyCropScale(1.5)
        XCTAssertFalse(viewModel.isAutoCropApplied)

        viewModel.autoCrop()
        viewModel.applyCropRotation(0.1)
        XCTAssertFalse(viewModel.isAutoCropApplied)
    }

    /// Nothing to level by (an imported clip with no horizon) changes nothing, so the button
    /// stays on Auto rotate and the notice says why.
    @MainActor
    func testAutoRotateFindingNothingLeavesTheButtonOnAuto() async throws {
        let viewModel = makeLevelingViewModel(rotation: nil)

        try await autoRotateAndWait(viewModel)

        XCTAssertFalse(viewModel.isAutoRotateApplied)
        XCTAssertEqual(viewModel.cropAdjustment.rotationRadians, 0)
        XCTAssertTrue(viewModel.isShowingNoHorizonNotice)
    }

    /// A trim is not a re-crop, so it is not a manual edit of the framing either: the fits
    /// stay on screen and their buttons keep offering the reset.
    @MainActor
    func testTrimmingLeavesTheResetButtonsInPlace() async throws {
        let viewModel = makeLevelingViewModel(rotation: 0.25)
        viewModel.autoCrop()
        try await autoRotateAndWait(viewModel)

        viewModel.trimStart(to: 1)

        XCTAssertTrue(viewModel.isAutoCropApplied)
        XCTAssertTrue(viewModel.isAutoRotateApplied)
    }

    // MARK: - Playback and mute

    @MainActor
    func testTogglePlaybackFlips() {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.isPlaying)
        viewModel.togglePlayback()
        XCTAssertTrue(viewModel.isPlaying)
        viewModel.togglePlayback()
        XCTAssertFalse(viewModel.isPlaying)
    }

    @MainActor
    func testToggleMuteFlips() {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.isMuted)
        viewModel.toggleMute()
        XCTAssertTrue(viewModel.isMuted)
    }

    // MARK: - Commit

    @MainActor
    func testResultReflectsTheEdits() {
        let viewModel = makeViewModel()

        viewModel.applyCropScale(2)
        viewModel.trimStart(to: 3)

        let result = viewModel.result
        XCTAssertEqual(result.window.startTime, 3, accuracy: 0.0001)
        XCTAssertEqual(result.cropRect, viewModel.cropRect)
        XCTAssertEqual(result.cropAdjustment.scale, 2, accuracy: 0.0001)
    }

    // MARK: - Overlay geometry

    @MainActor
    func testPreviewOverlayNeedsMediaInfo() {
        let viewModel = ClipEditorViewModel(source: makeSource(frames: twoPositionFrames()))

        XCTAssertNil(viewModel.previewOverlay)
    }

    @MainActor
    func testVisibleRangeSpansTheWholeAsset() {
        // The timeline shows the whole video (not a zoomed range around the window),
        // so a clip's position on it reads as "roughly this part of the video."
        let viewModel = makeViewModel(window: TrickWindow(startTime: 20, endTime: 23))

        let range = viewModel.visibleRange
        XCTAssertEqual(range?.lowerBound ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(range?.upperBound ?? -1, duration, accuracy: 0.0001)
    }

    @MainActor
    func testVisibleRangeIsNilBeforeDurationLoads() {
        let viewModel = ClipEditorViewModel(source: makeSource(frames: twoPositionFrames()))

        XCTAssertNil(viewModel.visibleRange)
    }

    @MainActor
    func testDurationLabelShowsOneDecimalSecond() {
        let viewModel = makeViewModel(window: TrickWindow(startTime: 1, endTime: 3.35))

        XCTAssertEqual(viewModel.durationLabel, "2.4s")
    }

    func testDisplayedCropRectWithIdentityTransformIsUnchanged() {
        // Fractions chosen exactly representable in Float so the assertion is exact — the
        // point here is the space mapping, not float dust.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.5, maxY: 0.75)

        let rect = ClipEditorViewModel.displayedCropRect(
            cropRect: crop,
            naturalSize: CGSize(width: 200, height: 100),
            preferredTransform: .identity)

        XCTAssertEqual(rect, CGRect(x: 50, y: 50, width: 100, height: 25))
    }

    func testDisplayedCropRectMapsARotatedTrackIntoDisplayedSpace() {
        // 90°-rotated track: landscape-encoded portrait video, encoded (0,0) at the
        // displayed top-right. The full encoded frame must become the portrait displayed
        // frame — a transform applied in the wrong space lands the overlay sideways.
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

        let rect = ClipEditorViewModel.displayedCropRect(
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)

        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1080, height: 1920))
    }

    func testDisplayedCropRectUsesTheDisplayedSizeForPartialRects() {
        // A partial rect discriminates the encoded-vs-displayed denormalization: with the
        // old (buggy) denormalize-in-encoded-size + map-through-transform, this
        // display-normalized rect lands at (0, 480, 1080, 960) instead of (270, 0, 540, 1920).
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

        let rect = ClipEditorViewModel.displayedCropRect(
            cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0, maxY: 1),
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotate90)

        XCTAssertEqual(rect, CGRect(x: 270, y: 0, width: 540, height: 1920))
    }

    func testDisplayedCropRectReturnsNilForDegenerateInputs() {
        XCTAssertNil(ClipEditorViewModel.displayedCropRect(
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            naturalSize: .zero,
            preferredTransform: .identity))

        let empty = NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0, maxY: 1)
        XCTAssertNil(ClipEditorViewModel.displayedCropRect(
            cropRect: empty,
            naturalSize: CGSize(width: 100, height: 100),
            preferredTransform: .identity))
    }

    // MARK: - Stage geometry

    func testMarkerRectIsTheLargestTargetRatioRectCenteredInTheInsetStage() {
        let stage = CGRect(x: 0, y: 113, width: 393, height: 500)

        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: 9.0 / 16.0)

        // 393 - 2*24 = 345 wide would need 613 of height; 500 - 2*12 = 476 fits instead.
        XCTAssertEqual(marker.height, 476, accuracy: 0.001)
        XCTAssertEqual(marker.width, 476 * 9 / 16, accuracy: 0.001)
        XCTAssertEqual(marker.midX, stage.midX, accuracy: 0.001)
        XCTAssertEqual(marker.midY, stage.midY, accuracy: 0.001)
    }

    func testMarkerRectIsWidthBoundOnAShortStage() {
        let stage = CGRect(x: 0, y: 0, width: 393, height: 1000)

        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: 9.0 / 16.0)

        XCTAssertEqual(marker.width, 345, accuracy: 0.001)
        XCTAssertEqual(marker.height, 345 * 16 / 9, accuracy: 0.001)
    }

    func testMarkerRectDoesNotDependOnTheClip() {
        let stage = CGRect(x: 0, y: 113, width: 393, height: 500)

        XCTAssertEqual(
            ClipEditorStage.markerRect(in: stage, aspectRatio: 9.0 / 16.0),
            ClipEditorStage.markerRect(in: stage, aspectRatio: 9.0 / 16.0))
    }

    func testVideoPlacementLandsTheCropRectOnTheMarker() throws {
        // A 1080x1920 frame with a 540x960 crop at its right edge: the crop must fill the
        // marker, so the video is twice the marker's size and hangs off its left.
        let marker = CGRect(x: 36, y: 125, width: 320, height: 320.0 * 16 / 9)

        let placement = try XCTUnwrap(ClipEditorStage.videoPlacement(
            videoSize: CGSize(width: 1080, height: 1920),
            cropRect: CGRect(x: 540, y: 480, width: 540, height: 960),
            marker: marker))

        let scale = 320.0 / 540.0
        XCTAssertEqual(placement.pointsPerDisplayedPixel, scale, accuracy: 0.0001)
        XCTAssertEqual(placement.frame.width, 1080 * scale, accuracy: 0.001)
        XCTAssertEqual(placement.frame.height, 1920 * scale, accuracy: 0.001)
        // The crop's center (810, 960) lands on the marker's center.
        XCTAssertEqual(placement.frame.minX + 810 * scale, marker.midX, accuracy: 0.001)
        XCTAssertEqual(placement.frame.minY + 960 * scale, marker.midY, accuracy: 0.001)
    }

    func testVideoPlacementOfALandscapeFrameRunsPastTheScreen() throws {
        // A 1920x1080 landscape frame with a 9:16 crop rect overhanging it top and bottom
        // (a hand-added clip's full-frame rect carries the marker past the frame the same
        // way): the crop still fills the marker, so the frame is laid out far wider than
        // any screen, with the overhang above and below it empty.
        let marker = CGRect(x: 36, y: 125, width: 320, height: 320.0 * 16 / 9)
        let cropHeight: CGFloat = 750.0 * 16 / 9
        let overhang = (cropHeight - 1080) / 2
        let crop = CGRect(x: 600, y: -overhang, width: 750, height: cropHeight)

        let placement = try XCTUnwrap(ClipEditorStage.videoPlacement(
            videoSize: CGSize(width: 1920, height: 1080), cropRect: crop, marker: marker))

        let scale = 320.0 / 750.0
        XCTAssertEqual(placement.pointsPerDisplayedPixel, scale, accuracy: 0.0001)
        XCTAssertEqual(placement.frame.width, 1920 * scale, accuracy: 0.001)
        XCTAssertGreaterThan(placement.frame.width, 393)
        // The frame sits inside the marker vertically, centered: the bars above and below
        // are the overhang at this scale.
        XCTAssertEqual(placement.frame.minY, marker.minY + overhang * scale, accuracy: 0.01)
        XCTAssertEqual(placement.frame.maxY, marker.maxY - overhang * scale, accuracy: 0.01)
    }

    func testVideoPlacementReturnsNilForDegenerateInputs() {
        let marker = CGRect(x: 0, y: 0, width: 320, height: 568)
        XCTAssertNil(ClipEditorStage.videoPlacement(
            videoSize: .zero, cropRect: CGRect(x: 0, y: 0, width: 1, height: 1), marker: marker))
        XCTAssertNil(ClipEditorStage.videoPlacement(
            videoSize: CGSize(width: 100, height: 100), cropRect: .zero, marker: marker))
        XCTAssertNil(ClipEditorStage.videoPlacement(
            videoSize: CGSize(width: 100, height: 100),
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1), marker: .zero))
    }

    // MARK: - Load failure

    /// `/dev/null` isn't a video, so the track loads fail: `prepare()` must surface
    /// `failedToLoad` instead of returning silently and leaving the screen on the
    /// loading placeholder forever.
    @MainActor
    func testPrepareSurfacesLoadFailure() async {
        let viewModel = ClipEditorViewModel(source: makeSource(frames: []))
        XCTAssertFalse(viewModel.failedToLoad)

        await viewModel.prepare()

        XCTAssertTrue(viewModel.failedToLoad)
        XCTAssertNil(viewModel.duration)
    }
}
