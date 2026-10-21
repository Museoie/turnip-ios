import CoreGraphics
import XCTest
@testable import Turnip

final class CropPathCalculatorTests: XCTestCase {
    private let landscape = CGSize(width: 1920, height: 1080)
    private let calculator = CropPathCalculator()

    /// A full 17-keypoint frame at `time`: the given points take the leading COCO names and every
    /// name left over sits at the origin below the confidence threshold, so a path that stopped
    /// filtering by confidence would be dragged to (0, 0).
    private func frame(at time: TimeInterval, _ points: [(x: Float, y: Float)]) -> PoseFrameResult {
        let located = zip(PoseKeypoint.names, points).map { name, point in
            PoseKeypoint(name: name, y: point.y, x: point.x, confidence: 0.9)
        }
        let unlocated = PoseKeypoint.names.dropFirst(points.count).map { name in
            PoseKeypoint(name: name, y: 0, x: 0, confidence: 0.05)
        }
        return PoseFrameResult(frameIndex: Int((time * 30).rounded()), timestamp: time,
                               keypoints: located + unlocated)
    }

    /// An athlete standing upright between y 0.3 and 0.7, `width` wide, left edge at `x`.
    private func athlete(at time: TimeInterval, x: Float, width: Float = 0.02) -> PoseFrameResult {
        frame(at: time, [(x: x, y: 0.3), (x: x + width, y: 0.7)])
    }

    private func centerX(_ rect: NormalizedRect) -> Float { (rect.minX + rect.maxX) / 2 }
    private func centerY(_ rect: NormalizedRect) -> Float { (rect.minY + rect.maxY) / 2 }

    func testNoLocatedKeypointYieldsNoPath() {
        let frames = (0..<5).map { frame(at: Double($0) * 0.1, []) }

        XCTAssertNil(calculator.cropPath(for: frames, renderedPixelSize: landscape))
    }

    func testUnknownFrameSizeYieldsNoPath() {
        let frames = (0..<5).map { athlete(at: Double($0) * 0.1, x: 0.5) }

        XCTAssertNil(calculator.cropPath(for: frames, renderedPixelSize: .zero))
    }

    /// Keypoint jitter on an athlete standing still is the case a moving crop turns into camera
    /// shake, so it gets a still crop centered on everything the window located.
    func testAJitteringStillAthleteGetsAStillCrop() throws {
        let frames = (0..<20).map { index in
            athlete(at: Double(index) * 0.1, x: index.isMultiple(of: 2) ? 0.505 : 0.495)
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        XCTAssertTrue(path.isStatic)
        XCTAssertEqual(centerX(path.keyframes[0].rect), 0.51, accuracy: 0.00001)
        XCTAssertEqual(centerY(path.keyframes[0].rect), 0.5, accuracy: 0.00001)
    }

    func testTheCropFollowsAnAthleteCrossingTheFrame() throws {
        let frames = (0..<40).map { athlete(at: Double($0) * 0.1, x: 0.2 + 0.015 * Float($0)) }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        XCTAssertFalse(path.isStatic)
        XCTAssertEqual(path.keyframes.count, 40)
        let centers = path.keyframes.map { centerX($0.rect) }
        XCTAssertTrue(zip(centers, centers.dropFirst()).allSatisfy { $0 < $1 }, "\(centers)")
        // Steady motion is followed exactly at both ends, not dragged toward the middle.
        XCTAssertEqual(centers[0], 0.21, accuracy: 0.0001)
        XCTAssertEqual(centers[39], 0.795, accuracy: 0.0001)
    }

    /// The clip never zooms: every keyframe is the rect the static crop would draw around the
    /// largest single sample, at the target ratio in pixels.
    func testEveryKeyframeHoldsTheLargestSamplesRect() throws {
        let frames = (0..<30).map { index -> PoseFrameResult in
            let height: Float = index < 15 ? 0.2 : 0.5
            let x = 0.2 + 0.02 * Float(index)
            return frame(at: Double(index) * 0.1, [(x: x, y: 0.4), (x: x + 0.02, y: 0.4 + height)])
        }
        let tallest = try XCTUnwrap(CropRectCalculator().cropRect(
            for: [frames[29]], renderedPixelSize: landscape))

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        for keyframe in path.keyframes {
            XCTAssertEqual(keyframe.rect.width, tallest.width, accuracy: 0.00001)
            XCTAssertEqual(keyframe.rect.height, tallest.height, accuracy: 0.00001)
            let pixelRatio = keyframe.rect.width * Float(landscape.width)
                / (keyframe.rect.height * Float(landscape.height))
            XCTAssertEqual(pixelRatio, 9.0 / 16.0, accuracy: 0.0001)
        }
    }

    /// Alternating keypoint noise four times the size of each step forward would make a crop that
    /// chased the raw centers step back on every other frame.
    func testJitterOnAMovingAthleteDoesNotShakeTheCrop() throws {
        let frames = (0..<40).map { index in
            let noise: Float = index.isMultiple(of: 2) ? 0.01 : -0.01
            return athlete(at: Double(index) * 0.1, x: 0.3 + 0.005 * Float(index) + noise)
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        XCTAssertFalse(path.isStatic)
        let centers = path.keyframes.map { centerX($0.rect) }
        XCTAssertTrue(zip(centers, centers.dropFirst()).allSatisfy { $0 <= $1 }, "\(centers)")
    }

    /// Smoothing lets the crop lag a sudden move; the containment step is what keeps the athlete
    /// in the shot anyway.
    func testEveryLocatedJointStaysInsideItsKeyframe() throws {
        let frames = (0..<30).map { index in
            athlete(at: Double(index) * 0.1, x: index < 15 ? 0.2 : 0.7, width: 0.05)
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        for (frame, keyframe) in zip(frames, path.keyframes) {
            for point in CropRectCalculator.locatedPoints(in: [frame]) {
                XCTAssertGreaterThanOrEqual(Float(point.x), keyframe.rect.minX - 0.00001, "t=\(keyframe.time)")
                XCTAssertLessThanOrEqual(Float(point.x), keyframe.rect.maxX + 0.00001, "t=\(keyframe.time)")
            }
        }
    }

    /// A joint misplaced in one detection, or a second person's arm caught in one frame, widens
    /// that sample's box alone. The de-spike takes it out before the path sees it, so the crop
    /// doesn't jerk toward it for one sample and back.
    func testAOneSampleOutlierDoesNotMoveThePath() throws {
        func crossing(outlierAt outlier: Int?) -> [PoseFrameResult] {
            (0..<30).map { index in
                let x = 0.2 + 0.01 * Float(index)
                guard index == outlier else { return athlete(at: Double(index) * 0.1, x: x) }
                return frame(at: Double(index) * 0.1, [(x: x, y: 0.3), (x: x + 0.02, y: 0.7), (x: x + 0.35, y: 0.5)])
            }
        }

        let clean = try XCTUnwrap(calculator.cropPath(for: crossing(outlierAt: nil), renderedPixelSize: landscape))
        let spiked = try XCTUnwrap(calculator.cropPath(for: crossing(outlierAt: 15), renderedPixelSize: landscape))
        let undespiked = try XCTUnwrap(CropPathCalculator(despikeSamples: 1)
            .cropPath(for: crossing(outlierAt: 15), renderedPixelSize: landscape))

        // Edge by edge, the outlier's other edges give way to a neighbour's, so its sample's box
        // can move by one sample's step (0.01 here): nothing like the outlier's 0.35.
        for (spikedKeyframe, cleanKeyframe) in zip(spiked.keyframes, clean.keyframes) {
            XCTAssertEqual(
                centerX(spikedKeyframe.rect), centerX(cleanKeyframe.rect), accuracy: 0.006,
                "t=\(spikedKeyframe.time)")
        }
        XCTAssertGreaterThan(
            centerX(undespiked.keyframes[15].rect), centerX(clean.keyframes[15].rect) + 0.05,
            "without the de-spike the outlier pulls its sample's crop toward it")
    }

    /// A median keeps steady motion and steps alike: away from the window's ends, each sample's
    /// box is still its own.
    func testTheDespikeLeavesSteadyMotionAlone() throws {
        let frames = (0..<30).map { athlete(at: Double($0) * 0.1, x: 0.2 + 0.01 * Float($0)) }

        let despiked = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))
        let raw = try XCTUnwrap(
            CropPathCalculator(despikeSamples: 1).cropPath(for: frames, renderedPixelSize: landscape))

        for index in 6..<24 {
            XCTAssertEqual(
                centerX(despiked.keyframes[index].rect), centerX(raw.keyframes[index].rect), accuracy: 0.002,
                "t=\(despiked.keyframes[index].time)")
        }
    }

    func testAFrameWithNoLocatedJointIsPlacedByItsNeighbours() throws {
        let frames = (0..<30).map { index in
            (10...12).contains(index)
                ? frame(at: Double(index) * 0.1, [])
                : athlete(at: Double(index) * 0.1, x: 0.2 + 0.015 * Float(index))
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        XCTAssertEqual(path.keyframes.count, 30)
        let athleteCenterAtFrame11: Float = 0.2 + 0.015 * 11 + 0.01
        XCTAssertEqual(centerX(path.keyframes[11].rect), athleteCenterAtFrame11, accuracy: 0.0001)
    }

    /// A trick window's lead-in and trailing buffers often hold frames where nothing was located.
    /// Continuing the fitted line into them would turn the last samples' jitter into a pan.
    func testUnlocatedFramesBeyondTheLocatedSpanKeepAStillCropStill() throws {
        let jittering = (0..<20).map { index in
            athlete(at: 1 + Double(index) * 0.1, x: index.isMultiple(of: 2) ? 0.505 : 0.495)
        }
        let leadIn = (0..<10).map { frame(at: Double($0) * 0.1, []) }
        let trailing = (0..<30).map { frame(at: 3 + Double($0) * 0.1, []) }

        let path = try XCTUnwrap(calculator.cropPath(
            for: leadIn + jittering + trailing, renderedPixelSize: landscape))

        XCTAssertTrue(path.isStatic)
        XCTAssertEqual(centerX(path.keyframes[0].rect), 0.51, accuracy: 0.00001)
    }

    func testUnlocatedFramesBeyondTheLocatedSpanHoldTheCropAtThatEnd() throws {
        let moving = (0..<20).map { athlete(at: Double($0) * 0.1, x: 0.2 + 0.015 * Float($0)) }
        let trailing = (0..<20).map { frame(at: 2 + Double($0) * 0.1, []) }

        let path = try XCTUnwrap(calculator.cropPath(for: moving + trailing, renderedPixelSize: landscape))

        XCTAssertEqual(path.keyframes.count, 40)
        let lastLocated = path.keyframes[19].rect
        for keyframe in path.keyframes[20...] {
            XCTAssertEqual(keyframe.rect, lastLocated, "t=\(keyframe.time)")
        }
    }

    /// The last located keyframe can sit off its smoothed center, shifted to keep a sudden move
    /// in; the frames after it hold that keyframe rather than stepping back to the center.
    func testUnlocatedFramesAfterAContainedJumpHoldTheShiftedKeyframe() throws {
        let located = (0..<20).map { index in
            athlete(at: Double(index) * 0.1, x: index < 18 ? 0.3 : 0.6)
        }
        let trailing = (0..<10).map { frame(at: 2 + Double($0) * 0.1, []) }

        let path = try XCTUnwrap(calculator.cropPath(for: located + trailing, renderedPixelSize: landscape))

        XCTAssertLessThanOrEqual(0.62, path.keyframes[19].rect.maxX + 0.00001)
        for keyframe in path.keyframes[20...] {
            XCTAssertEqual(keyframe.rect, path.keyframes[19].rect, "t=\(keyframe.time)")
        }
    }

    /// An athlete taller than a 9:16 crop of the frame's height can hold: the crop shrinks
    /// uniformly to the frame's height and keeps its ratio.
    func testAFullHeightAthleteShrinksTheCropToTheFrame() throws {
        let frames = (0..<20).map { index -> PoseFrameResult in
            let x = 0.3 + 0.02 * Float(index)
            return frame(at: Double(index) * 0.1, [(x: x, y: 0.05), (x: x + 0.05, y: 0.95)])
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        for keyframe in path.keyframes {
            XCTAssertEqual(keyframe.rect.minY, 0, accuracy: 0.00001)
            XCTAssertEqual(keyframe.rect.maxY, 1, accuracy: 0.00001)
            XCTAssertEqual(keyframe.rect.width * Float(landscape.width), 1080 * 9 / 16, accuracy: 0.01)
        }
    }

    /// A jump moves the athlete up and down a portrait frame; the crop follows on that axis, keeps
    /// the athlete in, and stops at the frame's bottom edge.
    func testTheCropFollowsVerticalMotionWithinTheFrame() throws {
        let portrait = CGSize(width: 1080, height: 1920)
        let frames = (0..<30).map { index -> PoseFrameResult in
            let top: Float = index < 20 ? 0.3 + 0.01 * Float(index) : 0.85
            return frame(at: Double(index) * 0.1, [(x: 0.5, y: top), (x: 0.52, y: top + 0.15)])
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: portrait))

        XCTAssertFalse(path.isStatic)
        let centers = path.keyframes.prefix(20).map { centerY($0.rect) }
        XCTAssertTrue(zip(centers, centers.dropFirst()).allSatisfy { $0 < $1 }, "\(centers)")
        for (frame, keyframe) in zip(frames, path.keyframes) {
            XCTAssertLessThanOrEqual(keyframe.rect.maxY, 1)
            for point in CropRectCalculator.locatedPoints(in: [frame]) {
                XCTAssertGreaterThanOrEqual(Float(point.y), keyframe.rect.minY - 0.00001, "t=\(keyframe.time)")
                XCTAssertLessThanOrEqual(Float(point.y), keyframe.rect.maxY + 0.00001, "t=\(keyframe.time)")
            }
        }
        XCTAssertEqual(path.keyframes[29].rect.maxY, 1, accuracy: 0.00001)
    }

    /// An athlete in the bottom-left corner pushes the padded crop past two edges at once.
    func testTheCropNeverLeavesTheFrame() throws {
        let frames = (0..<30).map { index -> PoseFrameResult in
            let x = 0.002 * Float(index)
            return frame(at: Double(index) * 0.1, [(x: x, y: 0.6), (x: x + 0.02, y: 0.99)])
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: landscape))

        for keyframe in path.keyframes {
            XCTAssertGreaterThanOrEqual(keyframe.rect.minX, 0)
            XCTAssertLessThanOrEqual(keyframe.rect.maxX, 1)
            XCTAssertGreaterThanOrEqual(keyframe.rect.minY, 0)
            XCTAssertLessThanOrEqual(keyframe.rect.maxY, 1)
        }
        XCTAssertEqual(path.keyframes[0].rect.minX, 0, accuracy: 0.00001)
        XCTAssertEqual(path.keyframes[0].rect.maxY, 1, accuracy: 0.00001)
    }

    /// A wide athlete — mid-roll, say — on a portrait frame leaves the crop room above and below,
    /// so drifting down it moves the crop without ever needing the containment step.
    func testTheCropFollowsVerticalDriftThatStaysInsideIt() throws {
        let portrait = CGSize(width: 1080, height: 1920)
        let frames = (0..<30).map { index -> PoseFrameResult in
            let y = 0.3 + 0.005 * Float(index)
            return frame(at: Double(index) * 0.1, [(x: 0.35, y: y), (x: 0.65, y: y + 0.02)])
        }

        let path = try XCTUnwrap(calculator.cropPath(for: frames, renderedPixelSize: portrait))

        XCTAssertFalse(path.isStatic)
        let centers = path.keyframes.map { centerY($0.rect) }
        XCTAssertTrue(zip(centers, centers.dropFirst()).allSatisfy { $0 < $1 }, "\(centers)")
    }

    /// Smoothing is measured in seconds, so the analysis granularity setting changes how often
    /// the athlete is sampled and not how the crop moves.
    func testTheSamplingRateDoesNotChangeThePath() throws {
        func frames(every interval: TimeInterval) -> [PoseFrameResult] {
            stride(from: 0.0, through: 4.0, by: interval).map { time in
                athlete(at: time, x: 0.3 + 0.2 * Float(sin(time * 1.5)))
            }
        }

        let coarse = try XCTUnwrap(calculator.cropPath(for: frames(every: 0.1), renderedPixelSize: landscape))
        let fine = try XCTUnwrap(calculator.cropPath(for: frames(every: 0.05), renderedPixelSize: landscape))

        for keyframe in coarse.keyframes {
            XCTAssertEqual(centerX(fine.rect(at: keyframe.time)), centerX(keyframe.rect), accuracy: 0.003,
                           "t=\(keyframe.time)")
        }
    }

    func testFramesOutOfTimeOrderGiveTheSamePath() throws {
        let frames = (0..<20).map { athlete(at: Double($0) * 0.1, x: 0.2 + 0.02 * Float($0)) }

        let sorted = calculator.cropPath(for: frames, renderedPixelSize: landscape)
        let shuffled = calculator.cropPath(for: frames.reversed(), renderedPixelSize: landscape)

        XCTAssertEqual(shuffled, sorted)
    }

    func testRectAtInterpolatesBetweenKeyframesAndHoldsOutsideThem() {
        let left = NormalizedRect(minX: 0, maxX: 0.2, minY: 0, maxY: 0.5)
        let right = NormalizedRect(minX: 0.4, maxX: 0.6, minY: 0.5, maxY: 1)
        let path = CropPath(keyframes: [CropKeyframe(time: 1, rect: left), CropKeyframe(time: 2, rect: right)])

        XCTAssertEqual(path.rect(at: 0), left)
        XCTAssertEqual(path.rect(at: 3), right)
        let halfway = path.rect(at: 1.5)
        XCTAssertEqual(halfway.minX, 0.2, accuracy: 0.00001)
        XCTAssertEqual(halfway.maxX, 0.4, accuracy: 0.00001)
        XCTAssertEqual(halfway.minY, 0.25, accuracy: 0.00001)
        XCTAssertEqual(halfway.maxY, 0.75, accuracy: 0.00001)
    }
}
