import CoreGraphics
import XCTest
@testable import Turnip

final class CropRectCalculatorTests: XCTestCase {
    /// Builds a full 17-keypoint frame: the given keypoints take the leading COCO names, and
    /// every name left over sits at the origin below the confidence threshold. A calculator
    /// that dropped the confidence filter would pull every box out to (0, 0), so each of these
    /// fixtures discriminates against that on its own.
    private func frame(
        index: Int = 0,
        _ keypoints: [(x: Float, y: Float, confidence: Float)]
    ) -> PoseFrameResult {
        let located = zip(PoseKeypoint.names, keypoints).map { name, keypoint in
            PoseKeypoint(name: name, y: keypoint.y, x: keypoint.x, confidence: keypoint.confidence)
        }
        let unlocated = PoseKeypoint.names.dropFirst(keypoints.count).map { name in
            PoseKeypoint(name: name, y: 0, x: 0, confidence: 0.05)
        }
        return PoseFrameResult(
            frameIndex: index,
            timestamp: Double(index) * 0.1,
            keypoints: located + unlocated
        )
    }

    private func confident(_ points: [(x: Float, y: Float)]) -> [(x: Float, y: Float, confidence: Float)] {
        points.map { (x: $0.x, y: $0.y, confidence: 0.9) }
    }

    private func assertRect(
        _ rect: NormalizedRect?,
        minX: Float,
        maxX: Float,
        minY: Float,
        maxY: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let rect else {
            return XCTFail("expected a crop rect, got nil", file: file, line: line)
        }
        XCTAssertEqual(rect.minX, minX, accuracy: 0.00001, "minX", file: file, line: line)
        XCTAssertEqual(rect.maxX, maxX, accuracy: 0.00001, "maxX", file: file, line: line)
        XCTAssertEqual(rect.minY, minY, accuracy: 0.00001, "minY", file: file, line: line)
        XCTAssertEqual(rect.maxY, maxY, accuracy: 0.00001, "maxY", file: file, line: line)
    }

    private func assertPixelRect(
        _ rect: CGRect,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rect.minX, x, accuracy: 0.001, "x", file: file, line: line)
        XCTAssertEqual(rect.minY, y, accuracy: 0.001, "y", file: file, line: line)
        XCTAssertEqual(rect.width, width, accuracy: 0.001, "width", file: file, line: line)
        XCTAssertEqual(rect.height, height, accuracy: 0.001, "height", file: file, line: line)
    }

    private let square = CGSize(width: 1000, height: 1000)

    func testBoxIsTheUnionAcrossEveryFrameInTheWindow() {
        let frames = [
            frame(index: 0, confident([(x: 0.40, y: 0.40), (x: 0.50, y: 0.60)])),
            frame(index: 1, confident([(x: 0.45, y: 0.35), (x: 0.55, y: 0.65)]))
        ]

        let rect = CropRectCalculator().cropRect(for: frames, sourcePixelSize: square)

        // Union x 0.40-0.55, y 0.35-0.65; padded to 0.225 x 0.45; 9:16 wants 0.253125 wide.
        assertRect(rect, minX: 0.3484375, maxX: 0.6015625, minY: 0.275, maxY: 0.725)
    }

    func testPaddingExpandsEachSideByAQuarterOfTheBox() {
        // 0.09 x 0.16 is already 9:16 on a square source, and padding scales both axes by 1.5,
        // so the aspect snap is a no-op here and the assertion sees padding alone.
        let frames = [frame(confident([(x: 0.455, y: 0.42), (x: 0.545, y: 0.58)]))]

        let rect = CropRectCalculator().cropRect(for: frames, sourcePixelSize: square)

        assertRect(rect, minX: 0.4325, maxX: 0.5675, minY: 0.38, maxY: 0.62)
    }

    func testBoxTallerThanTargetRatioGrowsWidthAroundTheCenter() {
        let frames = [frame(confident([(x: 0.45, y: 0.20), (x: 0.55, y: 0.80)]))]

        let rect = CropRectCalculator().cropRect(for: frames, sourcePixelSize: square)

        // Padded 0.15 x 0.90. Height is untouched; width grows to 0.9 * 9/16 around x 0.5.
        assertRect(rect, minX: 0.246875, maxX: 0.753125, minY: 0.05, maxY: 0.95)
    }

    func testRectOverhangingTheFrameEdgeSlidesInsideAndKeepsTheTargetRatio() {
        let frames = [frame(confident([(x: 0.02, y: 0.40), (x: 0.12, y: 0.50)]))]

        let rect = CropRectCalculator().cropRect(for: frames, sourcePixelSize: square)

        // Padding pushes minX to -0.005; the rect still fits, so it slides right instead of
        // being cut down, and stays 0.15 x 0.2666 = 9:16.
        assertRect(rect, minX: 0, maxX: 0.15, minY: 0.3166667, maxY: 0.5833333)
    }

    func testRectTallerThanTheFrameClampsAndAcceptsLetterbox() throws {
        let frames = [frame(confident([(x: 0.30, y: 0.35), (x: 0.70, y: 0.65)]))]

        let rect = try XCTUnwrap(CropRectCalculator().cropRect(for: frames, sourcePixelSize: square))

        // 9:16 on a 0.6-wide box wants 1.0667 of height, which no slide can fit. Width keeps
        // the whole athlete rather than shrinking to restore the ratio.
        assertRect(rect, minX: 0.2, maxX: 0.8, minY: 0, maxY: 1)
        let pixels = rect.denormalized(in: square)
        XCTAssertEqual(Float(pixels.width / pixels.height), 0.6, accuracy: 0.00001)
    }

    func testLowConfidenceKeypointsAreExcludedFromTheBox() {
        let frames = [
            frame([
                (x: 0.45, y: 0.45, confidence: 0.9),
                (x: 0.55, y: 0.55, confidence: 0.9),
                (x: 0.95, y: 0.95, confidence: 0.2),
                // The threshold is exclusive, so a keypoint sitting exactly on it is unusable.
                (x: 0.05, y: 0.05, confidence: PoseKeypoint.confidenceThreshold)
            ])
        ]

        let rect = CropRectCalculator().cropRect(for: frames, sourcePixelSize: square)

        assertRect(rect, minX: 0.425, maxX: 0.575, minY: 0.3666667, maxY: 0.6333333)
    }

    func testAspectRatioIsSnappedInPixelSpaceNotNormalizedSpace() throws {
        let landscape = CGSize(width: 1920, height: 1080)
        let frames = [frame(confident([(x: 0.45, y: 0.40), (x: 0.55, y: 0.60)]))]

        let rect = try XCTUnwrap(CropRectCalculator().cropRect(for: frames, sourcePixelSize: landscape))

        // The normalized rect is 0.15 x 0.4741 — deliberately not 9:16 in normalized units,
        // because the frame is 16:9 and only the pixel rect has to hit the target.
        assertRect(rect, minX: 0.425, maxX: 0.575, minY: 0.2629630, maxY: 0.7370370)
        assertPixelRect(rect.denormalized(in: landscape), x: 816, y: 284, width: 288, height: 512)
    }

    func testDenormalizedRectIsInSourcePixels() throws {
        let portrait = CGSize(width: 1080, height: 1920)
        let frames = [frame(confident([(x: 0.40, y: 0.45), (x: 0.60, y: 0.55)]))]

        let rect = try XCTUnwrap(CropRectCalculator().cropRect(for: frames, sourcePixelSize: portrait))

        assertRect(rect, minX: 0.35, maxX: 0.65, minY: 0.35, maxY: 0.65)
        assertPixelRect(rect.denormalized(in: portrait), x: 378, y: 672, width: 324, height: 576)
    }

    func testTargetAspectRatioIsConfigurable() {
        let frames = [frame(confident([(x: 0.40, y: 0.45), (x: 0.60, y: 0.55)]))]

        let rect = CropRectCalculator(targetAspectRatio: 1).cropRect(for: frames, sourcePixelSize: square)

        assertRect(rect, minX: 0.35, maxX: 0.65, minY: 0.35, maxY: 0.65)
    }

    func testReturnsNilWhenNoKeypointIsConfident() {
        let frames = [frame(index: 0, []), frame(index: 1, [])]

        XCTAssertNil(CropRectCalculator().cropRect(for: frames, sourcePixelSize: square))
        XCTAssertNil(CropRectCalculator().cropRect(for: [], sourcePixelSize: square))
    }

    func testReturnsNilWhenTheSourceDimensionsAreUnknown() {
        let frames = [frame(confident([(x: 0.45, y: 0.45), (x: 0.55, y: 0.55)]))]

        XCTAssertNil(CropRectCalculator().cropRect(for: frames, sourcePixelSize: .zero))
    }

    func testSingleConfidentKeypointProducesAFiniteRect() {
        let frames = [frame(confident([(x: 0.5, y: 0.5)]))]

        assertRect(CropRectCalculator().cropRect(for: frames, sourcePixelSize: square),
                   minX: 0.5, maxX: 0.5, minY: 0.5, maxY: 0.5)
    }
}
