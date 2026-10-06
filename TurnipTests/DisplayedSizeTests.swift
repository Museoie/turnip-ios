import CoreGraphics
import XCTest
@testable import Turnip

final class DisplayedSizeTests: XCTestCase {
    func testIdentityTransformReturnsInputSize() {
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(size.displayed(through: .identity), size)
    }

    func testNinetyDegreeRotationTransposesDimensions() {
        // The common phone-shot case: a landscape-encoded track shot in portrait.
        let landscape = CGSize(width: 1920, height: 1080)
        let rotated = landscape.displayed(
            through: CGAffineTransform(rotationAngle: .pi / 2))
        XCTAssertEqual(rotated.width, 1080, accuracy: 0.001)
        XCTAssertEqual(rotated.height, 1920, accuracy: 0.001)
    }

    func testOneEightyDegreeRotationKeepsDimensions() {
        let size = CGSize(width: 1920, height: 1080)
        let rotated = size.displayed(
            through: CGAffineTransform(rotationAngle: .pi))
        XCTAssertEqual(rotated.width, 1920, accuracy: 0.001)
        XCTAssertEqual(rotated.height, 1080, accuracy: 0.001)
    }

    func testMirroredTransformKeepsDimensionsNonNegative() {
        let size = CGSize(width: 1920, height: 1080)
        let mirrored = size.displayed(through: CGAffineTransform(scaleX: -1, y: 1))
        XCTAssertEqual(mirrored.width, 1920, accuracy: 0.001)
        XCTAssertEqual(mirrored.height, 1080, accuracy: 0.001)
    }
}
