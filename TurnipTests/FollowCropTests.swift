import AVFoundation
import CoreGraphics
import XCTest
@testable import Turnip

final class FollowCropTests: XCTestCase {
    // MARK: - MonotoneCubic

    func testTheCurvePassesThroughEveryKnotAndHoldsOutsideThem() {
        let curve = MonotoneCubic(times: [1, 2, 4], values: [10, 30, 20])

        XCTAssertEqual(curve.value(at: 1), 10, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 2), 30, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 4), 20, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 0), 10)
        XCTAssertEqual(curve.value(at: 9), 20)
    }

    /// With two knots the curve is the ease-in-out cubic: still at both ends, halfway at the
    /// midpoint, a quarter of the way in at 3/32 of the move.
    func testTwoKnotsAreTheEaseInOutCubic() {
        let curve = MonotoneCubic(times: [0, 1], values: [0, 1])

        XCTAssertEqual(curve.value(at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 0.25), 3 * 0.0625 - 2 * 0.015625, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 0.001), 0, accuracy: 1e-5, "the move starts from rest")
        XCTAssertEqual(curve.value(at: 0.999), 1, accuracy: 1e-5, "and comes to rest")
    }

    /// A crop that eased in and out of every keyframe would stop at each one while the athlete
    /// kept moving. Through a steady run of knots the curve keeps its speed instead.
    func testTheCurvePassesThroughAMiddleKnotWithoutStopping() {
        let curve = MonotoneCubic(times: [0, 1, 2, 3], values: [0, 10, 20, 30])

        let speedAtMiddleKnot = (curve.value(at: 1.01) - curve.value(at: 0.99)) / 0.02
        XCTAssertEqual(speedAtMiddleKnot, 10, accuracy: 0.5)
    }

    /// Never past a knot: between two knots the value stays within theirs, so a crop whose
    /// keyframes all lie inside the frame stays inside between them, and a turning knot is a
    /// stop rather than an overshoot.
    func testTheCurveNeverOvershootsAKnot() {
        let curve = MonotoneCubic(times: [0, 0.3, 1, 1.2, 3], values: [0, 50, 52, 0, 0])
        for step in 0...300 {
            let time = Double(step) / 100
            let value = curve.value(at: time)
            XCTAssertGreaterThanOrEqual(value, -1e-9, "at \(time)")
            XCTAssertLessThanOrEqual(value, 52 + 1e-9, "at \(time)")
        }
        // One-sided on either side: the curve is smooth through a knot in its speed but not in
        // its acceleration, which a centered difference would read as speed.
        XCTAssertEqual((curve.value(at: 1 + 1e-6) - curve.value(at: 1)) / 1e-6, 0, accuracy: 0.05)
        XCTAssertEqual((curve.value(at: 1) - curve.value(at: 1 - 1e-6)) / 1e-6, 0, accuracy: 0.05)
    }

    // MARK: - FollowPath

    func testAPathWithNoKeyframesHoldsItsRestingCenter() {
        let resting = FollowFraming(center: CGPoint(x: 5, y: 6), scale: 1.5, rotationRadians: 0.2)
        let path = FollowPath(keyframes: [], resting: resting)

        XCTAssertEqual(path.center(at: 3), CGPoint(x: 5, y: 6))
        XCTAssertEqual(path.framing(at: 3), resting)
        XCTAssertNil(path.movingSpan)
    }

    func testAPathMovesFromItsFirstKeyframeToItsLast() {
        let path = FollowPath(
            keyframes: [
                FollowKeyframe(time: 4, center: CGPoint(x: 30, y: 0)),
                FollowKeyframe(time: 2, center: CGPoint(x: 10, y: 0))
            ],
            resting: FollowFraming(center: .zero, scale: 1, rotationRadians: 0))

        XCTAssertEqual(path.movingSpan, 2...4)
        XCTAssertEqual(path.center(at: 1).x, 10, accuracy: 1e-9)
        XCTAssertEqual(path.center(at: 3).x, 20, accuracy: 1e-9)
        XCTAssertEqual(path.center(at: 5).x, 30, accuracy: 1e-9)
    }

    /// The zoom moves in proportion: on a curve through 1× and 4×, halfway in time is 2×, not
    /// 2.5×, so 1× to 2× takes as long as 2× to 4×.
    func testAPathZoomsInProportion() {
        let path = FollowPath(
            keyframes: [
                FollowKeyframe(time: 0, center: .zero, scale: 1),
                FollowKeyframe(time: 2, center: .zero, scale: 4)
            ],
            resting: FollowFraming(center: .zero, scale: 1, rotationRadians: 0))

        XCTAssertEqual(path.framing(at: 1).scale, 2, accuracy: 1e-9)
        XCTAssertEqual(path.framing(at: -1).scale, 1, accuracy: 1e-9)
        XCTAssertEqual(path.framing(at: 3).scale, 4, accuracy: 1e-9)
    }

    /// Each value moves on its own curve through the keyframes: the turn eases in and out of
    /// its keyframes like the center, independently of it, and isn't wrapped to a half turn.
    func testAPathTurnsOnItsOwnCurve() {
        let path = FollowPath(
            keyframes: [
                FollowKeyframe(time: 0, center: CGPoint(x: 0, y: 0), rotationRadians: 0),
                FollowKeyframe(time: 1, center: CGPoint(x: 100, y: 0), rotationRadians: 0),
                FollowKeyframe(time: 2, center: CGPoint(x: 100, y: 0), rotationRadians: 4)
            ],
            resting: FollowFraming(center: .zero, scale: 1, rotationRadians: 0))

        XCTAssertEqual(path.framing(at: 0.5).rotationRadians, 0, accuracy: 1e-9)
        XCTAssertEqual(path.framing(at: 1.5).rotationRadians, 2, accuracy: 1e-9)
        XCTAssertEqual(path.framing(at: 1.5).center.x, 100, accuracy: 1e-9)
        XCTAssertEqual(path.framing(at: 2).rotationRadians, 4, accuracy: 1e-9, "a turn past π stays unwrapped")
    }

    // MARK: - FollowKeyframe

    /// A keyframe is Auto follow's while its position, zoom and turn are all as Auto follow
    /// wrote them; a change to any one fills it.
    func testAKeyframeIsAutoFollowsUntilAnyOfItsThreeValuesChanges() {
        let auto = FollowKeyframe(
            time: 1, framing: FollowFraming(center: CGPoint(x: 10, y: 20), scale: 2, rotationRadians: 0.1),
            isAuto: true)
        XCTAssertTrue(auto.isAutoFollows)

        var moved = auto
        moved.center.x += 1
        var zoomed = auto
        zoomed.scale *= 1.1
        var turned = auto
        turned.rotationRadians += 0.01
        for changed in [moved, zoomed, turned] {
            XCTAssertFalse(changed.isAutoFollows)
            XCTAssertEqual(changed.autoFraming, auto.framing)
        }
        XCTAssertFalse(FollowKeyframe(time: 1, center: .zero).isAutoFollows, "one the user added")
        XCTAssertNil(FollowKeyframe(time: 1, center: .zero).autoFraming)
    }

    /// Auto rotate and Reset rotate turn every keyframe and the resting framing; a keyframe Auto
    /// follow wrote takes the turn as Auto follow's, so it stays hollow.
    func testSettingTheRotationTurnsEveryKeyframe() {
        var crop = FollowCrop(
            keyframes: [
                FollowKeyframe(
                    time: 0, framing: FollowFraming(center: .zero, scale: 2, rotationRadians: 0), isAuto: true),
                FollowKeyframe(time: 1, center: CGPoint(x: 5, y: 0), scale: 3, rotationRadians: 0.4)
            ],
            resting: FollowFraming(center: .zero, scale: 1, rotationRadians: 0), isAutoFollow: true)

        crop.setRotation(-0.05)

        XCTAssertEqual(crop.keyframes.map(\.rotationRadians), [-0.05, -0.05])
        XCTAssertEqual(crop.resting.rotationRadians, -0.05)
        XCTAssertTrue(crop.keyframes[0].isAutoFollows)
        XCTAssertNil(crop.keyframes[1].autoRotationRadians)
        XCTAssertEqual(crop.keyframes.map(\.scale), [2, 3])
        XCTAssertTrue(crop.isAutoFollow)
    }

    // MARK: - AutoFollow

    private let landscape = CGSize(width: 1920, height: 1080)
    private let fullFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// An athlete crossing the landscape frame left to right over 3 s, sampled every 0.1 s.
    private func crossingAthlete() -> [PoseFrameResult] {
        (0..<30).map { index in
            let x: Float = 0.2 + 0.02 * Float(index)
            return PoseFixture.frame(index: index, hip: (x: x, y: 0.6), upperBody: (x: x, y: 0.3))
        }
    }

    func testAutoFollowReducesTheAthletesPathToAFewKeyframes() throws {
        let fit = try XCTUnwrap(AutoFollow().fit(
            frames: crossingAthlete(), cropRect: fullFrame, videoSize: landscape, rotationRadians: 0))

        XCTAssertTrue(fit.moves)
        let crop = fit.crop
        XCTAssertTrue(crop.isAutoFollow)
        XCTAssertTrue(crop.isUntouchedAutoFollow)
        XCTAssertGreaterThanOrEqual(crop.keyframes.count, 2)
        XCTAssertLessThan(crop.keyframes.count, 10)
        XCTAssertEqual(crop.keyframes.map(\.time), crop.keyframes.map(\.time).sorted())
        XCTAssertTrue(crop.keyframes.allSatisfy { $0.autoCenter == $0.center })
    }

    /// The reduced curve keeps every joint inside the crop that the per-sample path kept, and
    /// stays within the drift tolerance of every sample's own center.
    func testAutoFollowsCurveHoldsTheAthleteAtEverySample() throws {
        let frames = crossingAthlete()
        let fit = try XCTUnwrap(AutoFollow().fit(
            frames: frames, cropRect: fullFrame, videoSize: landscape, rotationRadians: 0))
        let path = fit.crop.path
        let marker = ClipEditorViewModel.markerBox(around: fullFrame, aspectRatio: 9.0 / 16.0)
        for frame in frames {
            let framing = path.framing(at: frame.timestamp)
            let box = CGSize(width: marker.width / framing.scale, height: marker.height / framing.scale)
            let center = framing.center
            for point in CropRectCalculator.locatedPoints(in: [frame]) {
                XCTAssertLessThanOrEqual(abs(point.x * landscape.width - center.x), box.width / 2 + 0.5)
                XCTAssertLessThanOrEqual(abs(point.y * landscape.height - center.y), box.height / 2 + 0.5)
            }
        }
    }

    /// An athlete who stays put leaves nothing to follow: one keyframe, framed around every joint
    /// in the window at once, here widened to Auto follow's floor: a region 768 px tall.
    func testAutoFollowOnAStandingAthleteIsOneKeyframe() throws {
        let frames = (0..<30).map {
            PoseFixture.frame(index: $0, hip: (x: 0.5, y: 0.6), upperBody: (x: 0.5, y: 0.3))
        }
        let fit = try XCTUnwrap(AutoFollow().fit(
            frames: frames, cropRect: fullFrame, videoSize: landscape, rotationRadians: 0))
        let wholeWindow = try XCTUnwrap(ClipEditorViewModel.autoCropAdjustment(
            normalizedKeypoints: CropRectCalculator.locatedPoints(in: frames), cropRect: fullFrame,
            videoSize: landscape, rotationRadians: 0, calculator: CropRectCalculator()))

        XCTAssertFalse(fit.moves)
        XCTAssertEqual(fit.crop.keyframes.count, 1)
        // The full frame's marker box is 1920 wide; the floor's region is 432 × 768.
        XCTAssertGreaterThan(wholeWindow.scale, 1920 / 432, "the joints alone would frame tighter than the floor")
        XCTAssertEqual(fit.crop.keyframes[0].scale, 1920 / 432, accuracy: 1e-9)
        let center = AutoFollow.slidIntoFrame(
            FramingConversion.followCenter(of: wholeWindow, cropCenter: CGPoint(x: 960, y: 540)),
            box: CGSize(width: 432, height: 768), rotationRadians: 0, in: landscape)
        XCTAssertEqual(fit.crop.keyframes[0].center.x, center.x, accuracy: 1e-6)
        XCTAssertEqual(fit.crop.keyframes[0].center.y, center.y, accuracy: 1e-6)
    }

    // MARK: - AutoFollow's zoom

    private let fourK = CGSize(width: 3840, height: 2160)
    private var fourKFrame: CGRect { CGRect(origin: .zero, size: fourK) }

    /// An athlete `heights(time)` of the frame tall, centered at `x(time)`, sampled every 0.1 s for
    /// `seconds`.
    private func athlete(
        seconds: Double, x: (Double) -> Float = { _ in 0.5 }, height: (Double) -> Float
    ) -> [PoseFrameResult] {
        (0..<Int(seconds * 10)).map { index in
            let time = Double(index) / 10, half = height(time) / 2
            return PoseFixture.frame(
                index: index, hip: (x: x(time), y: 0.5 + half), upperBody: (x: x(time), y: 0.5 - half))
        }
    }

    /// Each keyframe's crop width in source pixels.
    private func widths(_ crop: FollowCrop, cropRect: CGRect) -> [CGFloat] {
        let marker = ClipEditorViewModel.markerBox(around: cropRect, aspectRatio: 9.0 / 16.0)
        return crop.keyframes.map { marker.width / $0.scale }
    }

    /// An athlete coming toward the camera in place: the crop zooms out with them, which is a
    /// move even though the center holds.
    func testAutoFollowZoomsOutAsTheAthleteComesCloser() throws {
        let frames = athlete(seconds: 5) { time in Float(0.4 + 0.4 * min(max((time - 1) / 3, 0), 1)) }

        let fit = try XCTUnwrap(AutoFollow().fit(
            frames: frames, cropRect: fourKFrame, videoSize: fourK, rotationRadians: 0))

        XCTAssertTrue(fit.moves, "a zoom with the center still is a move")
        let widths = widths(fit.crop, cropRect: fourKFrame)
        XCTAssertGreaterThanOrEqual(widths.count, 2)
        XCTAssertEqual(widths, widths.sorted(), "the crop only widens")
        // 0.4 of the frame, padded by a tenth each side, at 9:16: 583 px; 0.8: 1,166 px. The dead
        // zone lets the crop sit up to 12% short of a room it has stopped growing toward.
        let rooms: [CGFloat] = [0.4 * 2160 * 1.2 * 9 / 16, 0.8 * 2160 * 1.2 * 9 / 16]
        for (width, room) in zip([widths[0], widths[widths.count - 1]], rooms) {
            XCTAssertGreaterThanOrEqual(width, room / 1.12 - 1)
            XCTAssertLessThanOrEqual(width, room * 1.05)
        }
    }

    /// The reduced curve keeps the zoom within the envelope's tolerance of every sample's own:
    /// a brief need for room, with the center still, takes keyframes of its own.
    func testTheZoomCurveStaysWithinItsToleranceOfEverySample() throws {
        let frames = athlete(seconds: 6) { time in time >= 2 && time < 3.5 ? 0.8 : 0.45 }
        let follower = AutoFollow()

        let fit = try XCTUnwrap(follower.fit(
            frames: frames, cropRect: fourKFrame, videoSize: fourK, rotationRadians: 0))

        XCTAssertGreaterThanOrEqual(fit.crop.keyframes.count, 3)
        let needs = follower.pathCalculator.athletes(for: frames, renderedPixelSize: fourK)
            .map { $0.map { CGFloat($0.room.maxX - $0.room.minX) * fourK.width } }
        let expected = follower.zoom.widths(times: frames.map(\.timestamp), needs: needs)
            .map { min(max($0, follower.tightestLongerSide * 9 / 16), 1215) }
        let marker = ClipEditorViewModel.markerBox(around: fourKFrame, aspectRatio: 9.0 / 16.0)
        let path = fit.crop.path
        for (frame, width) in zip(frames, expected) {
            let drawn = marker.width / path.framing(at: frame.timestamp).scale
            XCTAssertLessThanOrEqual(abs(log(drawn / width)), log(1.05) + 1e-6, "at \(frame.timestamp) s")
        }
    }

    /// A stretch where the athlete needs less room, with the center still, takes keyframes of its
    /// own although a crop held wide would cut nothing and drift nowhere: the zoom check alone
    /// asks for them.
    func testTheZoomCheckAloneAddsKeyframesForAZoomIn() throws {
        let frames = athlete(seconds: 10) { time in time >= 2 && time < 7 ? 0.45 : 0.8 }

        let fit = try XCTUnwrap(AutoFollow().fit(
            frames: frames, cropRect: fourKFrame, videoSize: fourK, rotationRadians: 0))

        XCTAssertGreaterThanOrEqual(fit.crop.keyframes.count, 3)
        let widths = widths(fit.crop, cropRect: fourKFrame)
        XCTAssertLessThan(widths.min() ?? 0, (widths.max() ?? 0) / 1.15, "it zooms in between")
        XCTAssertTrue(Set(fit.crop.keyframes.map(\.center)).count == 1, "the center never moves")
    }

    /// However small the athlete, Auto follow never frames a region shorter than 768 source pixels
    /// on its longer side: export would enlarge it further and it would go soft.
    func testAutoFollowNeverZoomsTighterThanTheFloor() throws {
        let frames = athlete(seconds: 3, x: { time in Float(0.3 + 0.1 * time) }, height: { _ in 0.1 })

        let follower = AutoFollow()
        let fit = try XCTUnwrap(follower.fit(
            frames: frames, cropRect: fourKFrame, videoSize: fourK, rotationRadians: 0))

        XCTAssertEqual(follower.tightestLongerSide, 768)
        let marker = ClipEditorViewModel.markerBox(around: fourKFrame, aspectRatio: 9.0 / 16.0)
        for time in stride(from: 0.0, through: 3, by: 0.05) {
            let width = marker.width / fit.crop.path.framing(at: time).scale
            XCTAssertGreaterThanOrEqual(width, 768 * 9 / 16 - 0.01, "at \(time) s")
        }
    }

    /// An athlete taller than the frame can show gets the widest crop the turned frame allows,
    /// never wider.
    func testAutoFollowNeverZoomsWiderThanTheTurnedFrame() throws {
        let frames = athlete(seconds: 3, x: { time in Float(0.4 + 0.05 * time) }, height: { _ in 0.99 })

        let fit = try XCTUnwrap(AutoFollow().fit(
            frames: frames, cropRect: fullFrame, videoSize: landscape, rotationRadians: 0.2))

        let widest = AutoFollow.widestFitting(ratio: 9.0 / 16.0, rotationRadians: 0.2, in: landscape)
        for width in widths(fit.crop, cropRect: fullFrame) {
            XCTAssertLessThanOrEqual(width, widest + 0.01)
        }
    }

    /// Where the crop zooms and moves at once, the curves keep its turned footprint inside the
    /// frame between keyframes as well as at them.
    func testAZoomingMovingCropStaysInsideTheFrameBetweenKeyframes() throws {
        let rotation = 0.15
        let frames = athlete(
            seconds: 5, x: { time in Float(0.25 + 0.13 * time) },
            height: { time in Float(0.35 + 0.12 * time) })

        let fit = try XCTUnwrap(AutoFollow().fit(
            frames: frames, cropRect: fourKFrame, videoSize: fourK, rotationRadians: rotation))

        let marker = ClipEditorViewModel.markerBox(around: fourKFrame, aspectRatio: 9.0 / 16.0)
        let turn = CGAffineTransform(rotationAngle: -rotation)
        for time in stride(from: 0.0, through: 5, by: 1.0 / 60) {
            let framing = fit.crop.path.framing(at: time)
            let box = CGSize(width: marker.width / framing.scale, height: marker.height / framing.scale)
            for corner in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                let offset = CGPoint(x: corner.0 * box.width / 2, y: corner.1 * box.height / 2).applying(turn)
                let point = CGPoint(x: framing.center.x + offset.x, y: framing.center.y + offset.y)
                XCTAssertTrue(
                    CGRect(origin: .zero, size: fourK).insetBy(dx: -0.75, dy: -0.75).contains(point),
                    "at \(time) s a corner at \(point) is outside the frame")
            }
        }
    }

    func testAutoFollowWithNothingLocatedIsNil() {
        let frames = (0..<10).map { PoseFrameResult(frameIndex: $0, timestamp: Double($0) / 10, keypoints: []) }

        XCTAssertNil(AutoFollow().fit(frames: frames, cropRect: fullFrame, videoSize: landscape, rotationRadians: 0))
    }

    /// Turned, the crop's footprint on the frame is wider than the crop: every keyframe keeps
    /// the turned footprint inside the frame.
    func testAutoFollowKeepsATurnedCropInsideTheFrame() throws {
        let rotation = 0.2
        let fit = try XCTUnwrap(AutoFollow().fit(
            frames: crossingAthlete(), cropRect: fullFrame, videoSize: landscape, rotationRadians: rotation))
        let marker = ClipEditorViewModel.markerBox(around: fullFrame, aspectRatio: 9.0 / 16.0)
        let scale = fit.crop.keyframes[0].scale
        let box = CGSize(width: marker.width / scale, height: marker.height / scale)
        let turn = CGAffineTransform(rotationAngle: -rotation)
        for keyframe in fit.crop.keyframes {
            for corner in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                let offset = CGPoint(x: corner.0 * box.width / 2, y: corner.1 * box.height / 2).applying(turn)
                let point = CGPoint(x: keyframe.center.x + offset.x, y: keyframe.center.y + offset.y)
                XCTAssertTrue(
                    CGRect(origin: .zero, size: landscape).insetBy(dx: -0.5, dy: -0.5).contains(point),
                    "a turned corner at \(point) is outside the frame")
            }
        }
    }

    func testTheWholeFrameCropHoldsAtTheFramesCenterWithNoKeyframes() {
        let crop = FollowCrop.wholeFrame(
            cropRect: CGRect(x: 600, y: 0, width: 607.5, height: 1080), videoSize: landscape,
            rotationRadians: 0.1, aspectRatio: 9.0 / 16.0)

        XCTAssertTrue(crop.keyframes.isEmpty)
        XCTAssertEqual(crop.resting.center, CGPoint(x: 960, y: 540))
        XCTAssertEqual(crop.resting.rotationRadians, 0.1)
        XCTAssertFalse(crop.isAutoFollow)
        // The whole landscape frame's 9:16 box is 1920 wide; the marker's is 607.5.
        XCTAssertEqual(crop.resting.scale, 607.5 / 1920, accuracy: 1e-9)
    }

    // MARK: - FramingConversion

    /// The discriminating case is turned and zoomed: at identity any point would do.
    func testAnAdjustmentsFollowCenterIsThePointItDrawsAtTheMarkersCenter() {
        let adjustment = CropAdjustment(scale: 1.6, rotationRadians: 0.4, offset: CGSize(width: 37, height: -12))
        let cropCenter = CGPoint(x: 700, y: 400)

        let center = FramingConversion.followCenter(of: adjustment, cropCenter: cropCenter)

        // An adjustment draws a source point p at R·s·(p − cropCenter) + offset from the
        // marker's center: the follow center is the point drawn at the center.
        let drawn = CGPoint(
            x: (center.x - cropCenter.x) * adjustment.scale, y: (center.y - cropCenter.y) * adjustment.scale)
            .applying(CGAffineTransform(rotationAngle: adjustment.rotationRadians))
        XCTAssertEqual(drawn.x + adjustment.offset.width, 0, accuracy: 1e-9)
        XCTAssertEqual(drawn.y + adjustment.offset.height, 0, accuracy: 1e-9)
    }

    // MARK: - FollowPan

    /// One step per frame across the moving span, each the shift that puts the crop's center
    /// on the clip's crop center at that frame; before the first step the first keyframe's.
    func testThePanStepsOncePerFrame() {
        let crop = FollowCrop.uniform(
            scale: 1, rotationRadians: 0,
            keyframes: [
                FollowKeyframe(time: 1, center: CGPoint(x: 100, y: 50)),
                FollowKeyframe(time: 2, center: CGPoint(x: 300, y: 50))
            ],
            restingCenter: .zero, isAutoFollow: false)
        let frames = VideoFrameTimes.nominalFrames(across: 1...2, frameRate: 30)

        let pan = FollowPan(crop: crop, cropCenter: CGPoint(x: 200, y: 50), frames: frames)

        XCTAssertEqual(frames.count, 32, "thirty-one frames across the span and the first after it")
        XCTAssertEqual(pan.initial.shift, CGPoint(x: 100, y: 0))
        XCTAssertEqual(pan.framing(at: 0.5).shift, CGPoint(x: 100, y: 0))
        XCTAssertEqual(pan.framing(at: 1.5).shift.x, 0, accuracy: 1e-9)
        XCTAssertEqual(
            pan.framing(at: 1.5 + 0.5 / 30).shift.x, pan.framing(at: 1.5).shift.x, "steps, not glides")
        XCTAssertEqual(pan.framing(at: 5).shift, CGPoint(x: -100, y: 0))
    }

    func testAStillFollowCropHasNoSteps() {
        let crop = FollowCrop.uniform(
            scale: 1, rotationRadians: 0, keyframes: [FollowKeyframe(time: 1, center: CGPoint(x: 10, y: 10))],
            restingCenter: .zero, isAutoFollow: false)

        let pan = FollowPan(crop: crop, cropCenter: CGPoint(x: 30, y: 10), frames: [1, 2, 3])

        XCTAssertTrue(pan.steps.isEmpty)
        XCTAssertEqual(pan.initial.shift, CGPoint(x: 20, y: 0))
    }

    /// The real times come off the track's own samples: a 30 fps movie reads back on its
    /// thirtieths.
    func testFrameTimesAreReadOffTheTrack() async throws {
        let url = try await TestVideoWriter.writeTestVideo(frameCount: 90, width: 64, height: 36, fps: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = await VideoFrameTimes.load(from: AVURLAsset(url: url), over: 0...2)

        let times = try XCTUnwrap(loaded)
        XCTAssertGreaterThanOrEqual(times.times.count, 60)
        for (index, time) in times.times.prefix(60).enumerated() {
            XCTAssertEqual(time, Double(index) / 30, accuracy: 1e-6)
        }
        let across = try XCTUnwrap(times.frames(across: 1.01...1.09))
        XCTAssertEqual(across.count, 3, "the two frames inside and the first after")
        XCTAssertEqual(across[2], 33.0 / 30, accuracy: 1e-6)
    }

    func testRealFrameTimesCoverOnlyTheRangeRead() {
        let times = VideoFrameTimes(range: 0...2, times: [0, 0.4, 0.8, 1.2, 1.6, 2])

        XCTAssertEqual(times.frames(across: 0.5...1.3), [0.8, 1.2, 1.6])
        XCTAssertNil(times.frames(across: 1...3))
    }

    // MARK: - Export sampling

    func testExportSamplesEveryFrameWhereTheCropMovesAndTheSpansEnds() {
        let thirtieth = CMTime(value: 1, timescale: 30)
        let times = ClipExportTransform.sampleTimes(over: 0...3, moving: 1.01...1.09, frameDuration: thirtieth)

        XCTAssertEqual(times.count, 2 + 4)
        XCTAssertEqual(times[0], .zero)
        XCTAssertEqual(times[1], CMTime(value: 30, timescale: 30))
        XCTAssertEqual(times[4], CMTime(value: 33, timescale: 30))
        XCTAssertEqual(times[5].seconds, 3)
        XCTAssertEqual(
            ClipExportTransform.sampleTimes(over: 0...3, moving: nil, frameDuration: thirtieth).map(\.seconds), [0, 3])
    }

    /// The frames are exact multiples of the frame duration, never rounded: a 29.97 fps grid
    /// isn't a whole number of 600ths of a second.
    func testExportSamplesAnNTSCGridExactly() {
        let frame = CMTime(value: 1001, timescale: 30000)
        let times = ClipExportTransform.sampleTimes(over: 10...14, moving: 11...12, frameDuration: frame)

        for time in times.dropFirst().dropLast() {
            XCTAssertEqual(time.timescale, 30000)
            XCTAssertEqual(time.value % 1001, 0, "\(time.value) isn't on the grid")
        }
    }
}
