import AVFoundation
import CoreImage
import XCTest
@testable import Turnip

/// The editor's follow preview: the pan a blend of generations draws for a frame, the weights
/// SwiftUI animates between them, where the video layer goes, and the composition that draws the
/// frames upright.
final class FollowPreviewTests: XCTestCase {
    /// A pan that moves the picture 200 px left between 1 s and 2 s, one step per 30 fps frame.
    private let pan: FollowPan = {
        let crop = FollowCrop.uniform(
            scale: 1, rotationRadians: 0,
            keyframes: [
                FollowKeyframe(time: 1, center: CGPoint(x: 100, y: 50)),
                FollowKeyframe(time: 2, center: CGPoint(x: 300, y: 50))
            ],
            restingCenter: .zero, isAutoFollow: false)
        let frames = (30...60).map { TimeInterval($0) / 30 }
        return FollowPan(crop: crop, cropCenter: CGPoint(x: 200, y: 50), frames: frames)
    }()

    /// A pan that holds the picture at `shift` and `scale` throughout.
    private func still(_ shift: CGPoint, scale: CGFloat = 1) -> FollowPan {
        let crop = FollowCrop.uniform(
            scale: scale, rotationRadians: 0, keyframes: [], restingCenter: CGPoint(x: -shift.x, y: -shift.y),
            isAutoFollow: false)
        return FollowPan(crop: crop, cropCenter: .zero, frames: [])
    }

    /// A crop whose zoom and turn change between keyframes steps them with its center, frame by
    /// frame, each at the frame's own time.
    func testAPanStepsTheZoomAndTurnWithTheCenter() {
        let crop = FollowCrop(
            keyframes: [
                FollowKeyframe(time: 1, center: CGPoint(x: 100, y: 50), scale: 1, rotationRadians: 0),
                FollowKeyframe(time: 2, center: CGPoint(x: 300, y: 50), scale: 2, rotationRadians: 0.4)
            ],
            resting: FollowFraming(center: .zero, scale: 1, rotationRadians: 0), isAutoFollow: false)
        let frames = (30...60).map { TimeInterval($0) / 30 }
        let pan = FollowPan(crop: crop, cropCenter: CGPoint(x: 200, y: 50), frames: frames)

        XCTAssertEqual(pan.initial, PreviewFraming(shift: CGPoint(x: 100, y: 0), scale: 1, rotationRadians: 0))
        for time in frames {
            let expected = crop.path.framing(at: time)
            let framing = pan.framing(at: time + 0.4 / 30)
            XCTAssertEqual(framing.shift.x, 200 - expected.center.x, accuracy: 1e-9)
            XCTAssertEqual(framing.scale, expected.scale, accuracy: 1e-9)
            XCTAssertEqual(framing.rotationRadians, expected.rotationRadians, accuracy: 1e-9)
        }
        XCTAssertEqual(pan.framing(at: 9).scale, 2, accuracy: 1e-9)
    }

    /// Each generation's framing counts by its weight, at the frame's own time; a generation
    /// without a pan draws the unshifted frame.
    func testABlendDrawsEachPanByItsWeight() {
        let steady = PreviewPanBlend(pans: [3: pan], weights: PreviewPanWeights([3: 1]))
        XCTAssertEqual(steady.framing(at: 1.5), pan.framing(at: 1.5))
        XCTAssertEqual(PreviewPanBlend(pans: [:], weights: PreviewPanWeights([0: 1])).framing(at: 1.5), .identity)

        let zoomed = still(CGPoint(x: 40, y: 0), scale: 3)
        let easing = PreviewPanBlend(pans: [3: zoomed], weights: PreviewPanWeights([2: 0.25, 3: 0.75]))
        let framing = easing.framing(at: 1.5)
        XCTAssertEqual(framing.shift.x, 40 * 0.75, accuracy: 1e-9)
        XCTAssertEqual(framing.scale, 0.25 * 1 + 0.75 * 3, accuracy: 1e-9)
    }

    /// A live pinch and turn draw what the keyframe commits: the crop's center stays put, zoomed
    /// and turned about.
    func testALivePinchAndTurnKeepTheCropsCenter() {
        let followBlend = PreviewPanBlend(pans: [1: pan], weights: PreviewPanWeights([1: 1]))
        let follow = followBlend.framing(at: 1.5, gestureScale: 1.5, gestureRotation: 0.2)
        XCTAssertEqual(follow.shift, pan.framing(at: 1.5).shift)
        XCTAssertEqual(follow.scale, pan.framing(at: 1.5).scale * 1.5, accuracy: 1e-9)
        XCTAssertEqual(follow.rotationRadians, pan.framing(at: 1.5).rotationRadians + 0.2, accuracy: 1e-9)
    }

    /// The weights add, subtract and scale generation by generation, and a generation that comes
    /// to nothing drops out, so a finished ease compares equal to its target.
    func testWeightsWorkGenerationByGeneration() {
        let first = PreviewPanWeights([1: 1])
        let second = PreviewPanWeights([2: 1])
        XCTAssertEqual(first + second, PreviewPanWeights([1: 1, 2: 1]))
        XCTAssertEqual(second - first, PreviewPanWeights([1: -1, 2: 1]))
        XCTAssertEqual(first - first, .zero)
        XCTAssertEqual((first - first).values, [:])
        var scaled = second - first
        scaled.scale(by: 0.5)
        XCTAssertEqual(scaled, PreviewPanWeights([1: -0.5, 2: 0.5]))
        XCTAssertEqual(scaled.magnitudeSquared, 0.5, accuracy: 1e-12)
        XCTAssertEqual(PreviewPanWeights([1: 0, 2: 1]), second)
    }

    /// SwiftUI runs an animation that interrupts another by adding it to the one still running:
    /// the value is the target less what each animation has yet to travel. Done to the weights,
    /// that moves the pan by the same law as a zoom animated in the same transactions, and the
    /// weights always add up to the whole picture.
    func testAnInterruptedEaseMovesThePanAsTheZoomMoves() {
        let shifts = [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: -30), CGPoint(x: -60, y: 90)]
        let pans = [0: still(shifts[0]), 1: still(shifts[1]), 2: still(shifts[2])]
        let targets = [PreviewPanWeights([0: 1]), PreviewPanWeights([1: 1]), PreviewPanWeights([2: 1])]
        /// A value animated from `values[0]` to `values[1]`, then on to `values[2]` partway.
        func animated(_ values: [Double], _ first: Double, _ second: Double) -> Double {
            values[2] - (values[1] - values[0]) * (1 - first) - (values[2] - values[1]) * (1 - second)
        }
        // The second ease starts 0.15 s into the first; both run 0.4 s. Before it starts, the
        // first's target is the value's.
        for time in stride(from: 0.0, through: 0.6, by: 0.05) {
            let first = PreviewPanWeights.easeInOut(min(time / 0.4, 1))
            let second = time < 0.15 ? 0 : PreviewPanWeights.easeInOut(min((time - 0.15) / 0.4, 1))
            var firstRemaining = targets[1] - targets[0]
            firstRemaining.scale(by: 1 - first)
            var secondRemaining = targets[2] - targets[1]
            secondRemaining.scale(by: 1 - second)
            let weights = time < 0.15 ? targets[1] - firstRemaining : targets[2] - firstRemaining - secondRemaining
            XCTAssertEqual(weights.values.values.reduce(0, +), 1, accuracy: 1e-9, "at \(time) s")

            let shift = PreviewPanBlend(pans: pans, weights: weights).framing(at: 0).shift
            let expected = CGPoint(
                x: animated(shifts.map { Double($0.x) }, first, second),
                y: animated(shifts.map { Double($0.y) }, first, second))
            XCTAssertEqual(shift.x, expected.x, accuracy: 1e-9, "at \(time) s")
            XCTAssertEqual(shift.y, expected.y, accuracy: 1e-9, "at \(time) s")
        }
    }

    /// The video layer is the view's size, so the unshifted upright frame fills it, and a
    /// framing draws its center on the crop center and the rest of the frame zoomed and turned
    /// about it, at the view's points per displayed pixel.
    func testTheVideoLayerDrawsTheFramingAboutTheCropCenter() {
        let track = VideoTrackGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0))
        let view = CGRect(x: 0, y: 0, width: 270, height: 480)
        let cropCenter = CGPoint(x: 400, y: 1100)
        let center = CGPoint(x: 600, y: 900)
        let framing = PreviewFraming(
            shift: CGPoint(x: cropCenter.x - center.x, y: cropCenter.y - center.y), scale: 2, rotationRadians: 0.3)

        let placement = EditorVideoPlacement(track: track, bounds: view, cropCenter: cropCenter, framing: framing)

        XCTAssertEqual(placement.bounds, CGRect(x: 0, y: 0, width: 270, height: 480))
        /// Where the layer draws the source point `point`, in the view.
        func drawn(_ point: CGPoint) -> CGPoint {
            let inLayer = CGPoint(
                x: point.x * 0.25 - placement.anchorPoint.x * 270, y: point.y * 0.25 - placement.anchorPoint.y * 480)
                .applying(placement.transform)
            return CGPoint(x: placement.position.x + inLayer.x, y: placement.position.y + inLayer.y)
        }
        let marker = CGPoint(x: cropCenter.x * 0.25, y: cropCenter.y * 0.25)
        XCTAssertEqual(drawn(center).x, marker.x, accuracy: 1e-9)
        XCTAssertEqual(drawn(center).y, marker.y, accuracy: 1e-9)
        // 100 displayed pixels along the turned crop's own width axis lands 100 × 2 × 0.25 points
        // across the screen from the marker's center.
        let along = CGPoint(x: center.x + 100 * cos(-0.3), y: center.y + 100 * sin(-0.3))
        XCTAssertEqual(drawn(along).x, marker.x + 50, accuracy: 1e-9)
        XCTAssertEqual(drawn(along).y, marker.y, accuracy: 1e-9)
        let unshifted = EditorVideoPlacement(track: track, bounds: view, cropCenter: cropCenter, framing: .identity)
        XCTAssertEqual(unshifted.transform, .identity)
    }

    /// The editor item's composition draws a frame larger than the cap scaled down to it, and only
    /// an HDR track's through the tone mapping compositor, from iOS 18.
    func testTheCompositionDrawsWithinTheCap() throws {
        let turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        for (natural, scale) in [(CGSize(width: 1920, height: 1080), 1.0), (CGSize(width: 3840, height: 2160), 0.5)] {
            let transform = CGAffineTransform(
                a: turn.a, b: turn.b, c: turn.c, d: turn.d, tx: turn.tx * natural.width / 1920, ty: 0)
            let track = VideoTrackGeometry(naturalSize: natural, preferredTransform: transform)
            for isHDR in [false, true] {
                let composition = PreviewFrames.composition(
                    track: track, trackID: 1, duration: CMTime(value: 6, timescale: 1), frameRate: 30, isHDR: isHDR)
                XCTAssertEqual(composition.renderSize.width, track.displayedSize.width * scale, accuracy: 1)
                XCTAssertEqual(composition.renderSize.height, track.displayedSize.height * scale, accuracy: 1)
                guard #available(iOS 18.0, *), isHDR else {
                    XCTAssertNil(composition.customVideoCompositorClass)
                    let instruction = try XCTUnwrap(composition.instructions.first as? AVVideoCompositionInstruction)
                    var start = CGAffineTransform.identity, end = CGAffineTransform.identity
                    var range = CMTimeRange.zero
                    XCTAssertTrue(try XCTUnwrap(instruction.layerInstructions.first)
                        .getTransformRamp(for: .zero, start: &start, end: &end, timeRange: &range))
                    let upright = track.uprightTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    XCTAssertEqual(start, upright)
                    continue
                }
                XCTAssertTrue(composition.customVideoCompositorClass == PreviewCompositor.self)
                let instruction = try XCTUnwrap(composition.instructions.first as? PreviewCompositionInstruction)
                XCTAssertEqual(instruction.transform, PreviewCompositor.transform(track: track, scale: scale))
            }
        }
    }

    /// The compositor turns every orientation a camera writes upright, mirrored included: a mark in
    /// the encoded frame's top-left corner lands where the track's upright transform puts it.
    @available(iOS 18.0, *)
    func testTheCompositorDrawsEveryOrientationUpright() {
        let transforms: [CGAffineTransform] = [
            .identity,
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 4, ty: 0),
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 8, ty: 4),
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 8),
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 8, ty: 0)
        ]
        let source = pixelBuffer(width: 8, height: 4) { x, y in x < 2 && y < 2 ? 255 : 0 }
        for transform in transforms {
            let track = VideoTrackGeometry(naturalSize: CGSize(width: 8, height: 4), preferredTransform: transform)
            let upright = PreviewCompositor.transform(track: track, scale: 1)
            let image = PreviewCompositor.frame(from: source, transform: upright).image
            let drawn = render(image, size: track.displayedSize)
            let mark = CGPoint(x: 0.5, y: 0.5).applying(track.uprightTransform)
            let away = CGPoint(x: 6.5, y: 2.5).applying(track.uprightTransform)
            XCTAssertGreaterThan(value(in: drawn, at: mark), 200, "\(transform)")
            XCTAssertLessThan(value(in: drawn, at: away), 50, "\(transform)")
        }
    }

    /// A frame in standard range comes through as it was; an HLG frame is tone mapped into it.
    @available(iOS 18.0, *)
    func testTheCompositorTonemapsOnlyAnHDRFrame() {
        let standard = pixelBuffer(width: 2, height: 2) { _, _ in 85 }
        let square = CGSize(width: 2, height: 2)
        let kept = PreviewCompositor.frame(from: standard, transform: .identity)
        XCTAssertFalse(kept.isToneMapped)
        let drawn = render(kept.image, size: square)
        XCTAssertEqual(Double(value(in: drawn, at: CGPoint(x: 0.5, y: 0.5))), 85, accuracy: 1)

        let hlg = pixelBuffer(width: 2, height: 2) { _, _ in 230 }
        CVBufferSetAttachment(
            hlg, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(
            hlg, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(
            hlg, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        XCTAssertGreaterThan(
            CIImage(cvPixelBuffer: hlg, options: [.colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_HLG) as Any])
                .contentHeadroom, 1)
        let mapped = PreviewCompositor.frame(from: hlg, transform: .identity)
        XCTAssertEqual(mapped.image.contentHeadroom, 1, accuracy: 1e-6)
        XCTAssertTrue(mapped.isToneMapped)
        XCTAssertTrue(mapped.colorSpace === PreviewCompositor.colorSpace)
    }

    /// A BGRA buffer whose every channel at `(x, y)` (y down) is `level(x, y)`.
    private func pixelBuffer(width: Int, height: Int, level: (Int, Int) -> UInt8 = { _, _ in 0 }) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = level(x, y)
                pixel[1] = level(x, y)
                pixel[2] = level(x, y)
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    @available(iOS 18.0, *)
    private func render(_ image: CIImage, size: CGSize) -> CVPixelBuffer {
        let output = pixelBuffer(width: Int(size.width), height: Int(size.height))
        CIContext().render(
            image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: PreviewCompositor.colorSpace)
        return output
    }

    /// The green channel of the pixel containing `point` (y down).
    private func value(in buffer: CVPixelBuffer, at point: CGPoint) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return base[Int(point.y) * CVPixelBufferGetBytesPerRow(buffer) + Int(point.x) * 4 + 1]
    }
}

private extension PreviewPanWeights {
    /// SwiftUI's `.easeInOut`: the cubic Bézier through (0.42, 0) and (0.58, 1).
    static func easeInOut(_ fraction: Double) -> Double {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }
        func bezier(_ along: Double, _ first: Double, _ second: Double) -> Double {
            let rest = 1 - along
            return 3 * rest * rest * along * first + 3 * rest * along * along * second + along * along * along
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if bezier(mid, 0.42, 0.58) < fraction { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, 0, 1)
    }
}
