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

    /// A pan that holds the picture at `shift` throughout.
    private func still(_ shift: CGPoint) -> FollowPan {
        let crop = FollowCrop.uniform(
            scale: 1, rotationRadians: 0, keyframes: [], restingCenter: CGPoint(x: -shift.x, y: -shift.y),
            isAutoFollow: false)
        return FollowPan(crop: crop, cropCenter: .zero, frames: [])
    }

    func testAMovedPanMovesEveryStep() {
        let moved = pan.moved(by: CGPoint(x: 10, y: -4))
        XCTAssertEqual(moved.initial, CGPoint(x: pan.initial.x + 10, y: pan.initial.y - 4))
        for (step, original) in zip(moved.steps, pan.steps) {
            XCTAssertEqual(step.time, original.time)
            XCTAssertEqual(step.shift, CGPoint(x: original.shift.x + 10, y: original.shift.y - 4))
        }
    }

    /// Each generation's pan counts by its weight, at the frame's own time; a generation without
    /// a pan, as Still has, draws the picture unshifted.
    func testABlendDrawsEachPanByItsWeight() {
        let steady = PreviewPanBlend(pans: [3: pan], weights: PreviewPanWeights([3: 1]))
        XCTAssertEqual(steady.shift(at: 1.5), pan.shift(at: 1.5))
        XCTAssertEqual(PreviewPanBlend(pans: [:], weights: PreviewPanWeights([0: 1])).shift(at: 1.5), .zero)

        let easing = PreviewPanBlend(pans: [3: pan], weights: PreviewPanWeights([2: 0.25, 3: 0.75]))
        for time in [1.2, 1.5, 1.8] {
            XCTAssertEqual(easing.shift(at: time).x, pan.shift(at: time).x * 0.75, accuracy: 1e-9)
            XCTAssertEqual(easing.shift(at: time).y, pan.shift(at: time).y * 0.75, accuracy: 1e-9)
        }
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

            let shift = PreviewPanBlend(pans: pans, weights: weights).shift(at: 0)
            let expected = CGPoint(
                x: animated(shifts.map { Double($0.x) }, first, second),
                y: animated(shifts.map { Double($0.y) }, first, second))
            XCTAssertEqual(shift.x, expected.x, accuracy: 1e-9, "at \(time) s")
            XCTAssertEqual(shift.y, expected.y, accuracy: 1e-9, "at \(time) s")
        }
    }

    /// The video layer is the view's size, so the upright frame fills it, moved by the pan at the
    /// view's points per displayed pixel.
    func testTheVideoLayerFillsTheViewMovedByThePan() {
        let track = VideoTrackGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0))
        let view = CGRect(x: 0, y: 0, width: 270, height: 480)
        let placement = EditorVideoPlacement(track: track, bounds: view, shift: CGPoint(x: 40, y: -12))
        XCTAssertEqual(placement.bounds, CGRect(x: 0, y: 0, width: 270, height: 480))
        XCTAssertEqual(placement.position.x, 135 + 40 * 0.25, accuracy: 1e-9)
        XCTAssertEqual(placement.position.y, 240 - 12 * 0.25, accuracy: 1e-9)
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
