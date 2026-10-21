import AVFoundation
import XCTest
@testable import Turnip

/// The editor's follow preview drawn into the frames: the pan an ease draws at each moment, and
/// the composition's canvas and per-frame transforms.
final class FollowPreviewTests: XCTestCase {
    /// A pan that moves the picture 200 px left between 1 s and 2 s, one step per 30 fps frame.
    private let pan: FollowPan = {
        let crop = FollowCrop(
            scale: 1, rotationRadians: 0,
            keyframes: [
                FollowKeyframe(time: 1, center: CGPoint(x: 100, y: 50)),
                FollowKeyframe(time: 2, center: CGPoint(x: 300, y: 50))
            ],
            restingCenter: .zero, isAutoFollow: false)
        let frames = (30...60).map { TimeInterval($0) / 30 }
        return FollowPan(crop: crop, cropCenter: CGPoint(x: 200, y: 50), frames: frames)
    }()

    private let duration = PreviewPan.easeDuration

    func testASteadyPanDrawsItsOwnShiftAndNoPanDrawsNone() {
        XCTAssertEqual(PreviewPan.steady(pan).shift(at: 1.5), pan.shift(at: 1.5))
        XCTAssertEqual(PreviewPan.steady(nil).shift(at: 1.5), .zero)
    }

    /// An ease starts on exactly what the frames showed, arrives on the target after
    /// `easeDuration` of item time, and shows the target before its anchor, where only a loop or
    /// a seek takes the player.
    func testAnEaseRunsFromTheFramesShiftOntoTheTargetOnTheItemsClock() {
        let ease = PreviewPan.easing(from: .steady(nil), target: pan, anchor: 1.2, progress: 0)
        XCTAssertEqual(ease.shift(at: 1.2), .zero)
        let arrived = 1.2 + duration
        XCTAssertEqual(ease.shift(at: arrived).x, pan.shift(at: arrived).x, accuracy: 1e-9)
        XCTAssertEqual(ease.shift(at: 1.0), pan.shift(at: 1.0))
        let halfway = ease.shift(at: 1.2 + duration / 2)
        XCTAssertEqual(halfway.x, pan.shift(at: 1.2 + duration / 2).x / 2, accuracy: 1e-6)
    }

    /// A paused ease is redrawn with its progress stepped on the wall clock and its anchor on the
    /// frame on screen; resuming carries on from that progress on the item's clock.
    func testAnEaseCarriesOnFromItsProgressAtTheAnchor() {
        let ease = PreviewPan.easing(from: .steady(nil), target: pan, anchor: 1.5, progress: 0.75)
        XCTAssertEqual(ease.progress(at: 1.5), 0.75)
        XCTAssertEqual(ease.progress(at: 1.5 + duration / 4) ?? 0, 1, accuracy: 1e-9)
        let travel = PreviewPan.easeInOut(0.75)
        XCTAssertEqual(ease.shift(at: 1.5).x, pan.shift(at: 1.5).x * travel, accuracy: 1e-6)
        XCTAssertEqual(ease.easingSpans, [1.5...(1.5 + duration / 4)])
        XCTAssertNil(PreviewPan.steady(pan).progress(at: 1.5))
    }

    /// A new ease over one still running starts from wherever the running one has the picture.
    func testAnEaseOverAnEaseStartsFromTheRunningOne() {
        let running = PreviewPan.easing(from: .steady(nil), target: pan, anchor: 1.2, progress: 0)
        let next = PreviewPan.easing(from: running, target: nil, anchor: 1.3, progress: 0)
        XCTAssertEqual(next.shift(at: 1.3), running.shift(at: 1.3))
        XCTAssertEqual(next.target, nil)
        XCTAssertEqual(next.easingSpans.count, 2)
        XCTAssertEqual(next.pans, [pan])
    }

    /// The zoom's curve: SwiftUI's `.easeInOut`, the cubic Bézier through (0.42, 0) and (0.58, 1).
    func testTheEaseCurveIsTheZoomsEaseInOut() {
        XCTAssertEqual(PreviewPan.easeInOut(0), 0, accuracy: 1e-9)
        XCTAssertEqual(PreviewPan.easeInOut(1), 1, accuracy: 1e-9)
        XCTAssertEqual(PreviewPan.easeInOut(0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(PreviewPan.easeInOut(0.25), 0.1291, accuracy: 1e-3)
        for step in 0...20 {
            let fraction = Double(step) / 20
            XCTAssertEqual(PreviewPan.easeInOut(fraction) + PreviewPan.easeInOut(1 - fraction), 1, accuracy: 1e-6)
        }
    }

    func testAMovedPanMovesEveryStep() {
        let moved = pan.moved(by: CGPoint(x: 10, y: -4))
        XCTAssertEqual(moved.initial, CGPoint(x: pan.initial.x + 10, y: pan.initial.y - 4))
        for (step, original) in zip(moved.steps, pan.steps) {
            XCTAssertEqual(step.time, original.time)
            XCTAssertEqual(step.shift, CGPoint(x: original.shift.x + 10, y: original.shift.y - 4))
        }
    }

    /// The canvas reaches as far as the frame's farther edge from the crop's center, so a curve
    /// that stays in the frame never pushes the picture off it, or further for a pan that does.
    func testTheCanvasReachesAsFarAsAPanCanMoveThePicture() {
        let size = CGSize(width: 640, height: 360)
        XCTAssertEqual(
            FollowPreviewComposition.padding(videoSize: size, cropCenter: CGPoint(x: 200, y: 180), pans: []),
            CGSize(width: 440, height: 180))
        XCTAssertEqual(
            FollowPreviewComposition.padding(videoSize: size, cropCenter: CGPoint(x: 600, y: 180), pans: [pan]),
            CGSize(width: 600, height: 180))
        let far = pan.moved(by: CGPoint(x: -900, y: 0))
        XCTAssertEqual(
            FollowPreviewComposition.padding(videoSize: size, cropCenter: CGPoint(x: 200, y: 180), pans: [far]).width,
            1000)
    }

    /// Each frame is drawn at its own shift: uprighted, moved onto the canvas by the padding and
    /// the pan, and scaled when the canvas is too large to draw at full size.
    func testTheCompositionDrawsEachFrameAtItsShift() throws {
        let geometry = VideoTrackGeometry(naturalSize: CGSize(width: 640, height: 360), preferredTransform: .identity)
        let padding = CGSize(width: 440, height: 180)
        let preview = PreviewPan.easing(from: .steady(nil), target: pan, anchor: 1.2, progress: 0)
        let frames = (36...48).map { TimeInterval($0) / 30 }
        let composition = FollowPreviewComposition(
            pan: preview, frames: frames, padding: padding, geometry: geometry, trackID: 1,
            duration: CMTime(value: 6, timescale: 1), frameRate: 30)
        XCTAssertEqual(composition.renderScale, 1)
        XCTAssertEqual(composition.videoComposition.renderSize, CGSize(width: 1520, height: 720))
        let instruction = try XCTUnwrap(
            composition.videoComposition.instructions.first as? AVVideoCompositionInstruction)
        let layer = try XCTUnwrap(instruction.layerInstructions.first)
        for time in [1.0, 1.2, 1.3, 1.5, 1.8] {
            var start = CGAffineTransform.identity, end = CGAffineTransform.identity
            var range = CMTimeRange.zero
            XCTAssertTrue(layer.getTransformRamp(
                for: CMTime(value: CMTimeValue(time * 90_000) + 1, timescale: 90_000),
                start: &start, end: &end, timeRange: &range))
            let expected = preview.shift(at: time)
            XCTAssertEqual(start.tx, padding.width + expected.x, accuracy: 1e-6, "at \(time) s")
            XCTAssertEqual(start.ty, padding.height + expected.y, accuracy: 1e-6, "at \(time) s")
        }
    }

    func testALargeCanvasDrawsScaledDown() {
        let geometry = VideoTrackGeometry(naturalSize: CGSize(width: 3840, height: 2160), preferredTransform: .identity)
        let composition = FollowPreviewComposition(
            pan: .steady(nil), frames: [], padding: CGSize(width: 1920, height: 1080), geometry: geometry,
            trackID: 1, duration: CMTime(value: 6, timescale: 1), frameRate: 30)
        XCTAssertEqual(composition.renderScale, 4096 / 7680, accuracy: 1e-9)
        XCTAssertEqual(composition.videoComposition.renderSize, CGSize(width: 4096, height: 2304))
    }
}
