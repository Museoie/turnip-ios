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
            isKept: true,
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

    // MARK: - Live crop recompute

    @MainActor
    func testTrimStartRecomputesCropRectFromFramesInPlay() {
        let frames = twoPositionFrames()
        let viewModel = makeViewModel(window: TrickWindow(startTime: 0, endTime: 3.9), frames: frames)

        let before = viewModel.cropRect
        // Sanity: the full window's rect covers the athlete's whole travel, x 0.28...0.72.
        XCTAssertLessThan(before.minX, 0.3)

        // Trim the start past the early position: only the late frames drive the rect now.
        viewModel.trimStart(to: 2.0)

        let after = viewModel.cropRect
        guard let expected = CropRectCalculator().cropRect(
            for: frames.filter { $0.timestamp >= 2.0 && $0.timestamp <= 3.9 },
            sourcePixelSize: naturalSize)
        else {
            return XCTFail("the trimmed window's frames should yield a crop rect")
        }
        XCTAssertEqual(after, expected)
        // Discriminating: the rect moved right with the window, so a recompute that ignored
        // the new window — or never ran — fails here.
        XCTAssertGreaterThan(after.minX, before.minX)
    }

    @MainActor
    func testCropRectHoldsWhenTrimmedIntoKeypointFreeFrames() {
        // Frames 20..<40 carry no usable keypoints; trimming into them must not yank the
        // preview to the full frame mid-drag.
        let positioned = (0..<20).map { 0.48 + 0.04 * Float($0) / 19 }
        let frames = PoseFixture.frames(
            hipXPositions: positioned + [Float](repeating: 0.5, count: 20),
            blankFrames: Set(20..<40))
        let viewModel = makeViewModel(window: TrickWindow(startTime: 0, endTime: 3.9), frames: frames)

        let before = viewModel.cropRect
        viewModel.trimStart(to: 2.5)

        XCTAssertEqual(viewModel.window.startTime, 2.5, accuracy: 0.0001)
        XCTAssertEqual(viewModel.cropRect, before)
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

    // MARK: - Keep toggle and commit

    @MainActor
    func testToggleKeepFlips() {
        let viewModel = makeViewModel()

        XCTAssertTrue(viewModel.isKept)
        viewModel.toggleKeep()
        XCTAssertFalse(viewModel.isKept)
    }

    @MainActor
    func testResultReflectsTheEdits() {
        let viewModel = makeViewModel()

        viewModel.toggleKeep()
        viewModel.trimStart(to: 3)

        let result = viewModel.result
        XCTAssertFalse(result.isKept)
        XCTAssertEqual(result.window.startTime, 3, accuracy: 0.0001)
        XCTAssertEqual(result.cropRect, viewModel.cropRect)
    }

    // MARK: - Overlay geometry

    @MainActor
    func testPreviewOverlayNeedsMediaInfo() {
        let viewModel = ClipEditorViewModel(source: makeSource(frames: twoPositionFrames()))

        XCTAssertNil(viewModel.previewOverlay)
    }

    @MainActor
    func testVisibleRangePadsTheWindowWithContext() {
        let viewModel = makeViewModel(window: TrickWindow(startTime: 20, endTime: 23))

        // Padding is max(window duration, 2s) = 3s each side.
        let range = viewModel.visibleRange
        XCTAssertEqual(range?.lowerBound ?? -1, 17, accuracy: 0.0001)
        XCTAssertEqual(range?.upperBound ?? -1, 26, accuracy: 0.0001)
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
