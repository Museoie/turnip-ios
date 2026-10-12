import CoreGraphics
import XCTest
@testable import Turnip

final class VideoTrackGeometryTests: XCTestCase {
    /// Landscape-encoded portrait video, encoded (0,0) at the displayed top-right — the
    /// discriminating case for every mapping here, since identity can't tell encoded space
    /// from displayed space.
    private let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
    private let landscape = CGSize(width: 1920, height: 1080)

    func testDisplayedSizeAppliesPreferredTransform() {
        XCTAssertEqual(
            VideoTrackGeometry(naturalSize: landscape, preferredTransform: rotate90).displayedSize,
            CGSize(width: 1080, height: 1920))
        XCTAssertEqual(
            VideoTrackGeometry(naturalSize: landscape, preferredTransform: .identity).displayedSize,
            landscape)
    }

    func testUprightTransformLandsAnOffOriginRotationAtTheOrigin() {
        // A bare rotation about the origin (no normalizing translation) puts the content at
        // negative x; the upright transform must bring it back to [0, displayedSize].
        let bareRotation = CGAffineTransform(rotationAngle: .pi / 2)
        let geometry = VideoTrackGeometry(naturalSize: landscape, preferredTransform: bareRotation)

        let upright = CGRect(origin: .zero, size: landscape).applying(geometry.uprightTransform)

        XCTAssertEqual(upright.minX, 0, accuracy: 0.001)
        XCTAssertEqual(upright.minY, 0, accuracy: 0.001)
        XCTAssertEqual(upright.width, 1080, accuracy: 0.001)
        XCTAssertEqual(upright.height, 1920, accuracy: 0.001)
    }

    func testDisplayedCropRectWithIdentityTransformIsUnchanged() {
        // Fractions chosen exactly representable in Float so the assertion is exact — the
        // point here is the space mapping, not float dust.
        let crop = NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.5, maxY: 0.75)
        let geometry = VideoTrackGeometry(
            naturalSize: CGSize(width: 200, height: 100), preferredTransform: .identity)

        XCTAssertEqual(geometry.displayedCropRect(crop), CGRect(x: 50, y: 50, width: 100, height: 25))
    }

    func testDisplayedCropRectMapsARotatedTrackIntoDisplayedSpace() {
        let geometry = VideoTrackGeometry(naturalSize: landscape, preferredTransform: rotate90)

        XCTAssertEqual(
            geometry.displayedCropRect(NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
            CGRect(x: 0, y: 0, width: 1080, height: 1920))
    }

    func testDisplayedCropRectUsesTheDisplayedSizeForPartialRects() {
        // A partial rect discriminates the encoded-vs-displayed denormalization:
        // denormalizing in the encoded size and then mapping through the transform would land
        // this display-normalized rect at (0, 480, 1080, 960) instead of (270, 0, 540, 1920).
        let geometry = VideoTrackGeometry(naturalSize: landscape, preferredTransform: rotate90)

        XCTAssertEqual(
            geometry.displayedCropRect(NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0, maxY: 1)),
            CGRect(x: 270, y: 0, width: 540, height: 1920))
    }

    func testDisplayedCropRectReturnsNilForDegenerateInputs() {
        XCTAssertNil(
            VideoTrackGeometry(naturalSize: .zero, preferredTransform: .identity)
                .displayedCropRect(NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)))

        XCTAssertNil(
            VideoTrackGeometry(naturalSize: CGSize(width: 100, height: 100), preferredTransform: .identity)
                .displayedCropRect(NormalizedRect(minX: 0.5, maxX: 0.5, minY: 0, maxY: 1)))
    }
}
