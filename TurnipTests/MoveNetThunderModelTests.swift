import XCTest
@testable import Turnip

/// `MoveNetThunderModel.validateInputShape` is pure so it can be exercised without the
/// gitignored `.tflite` — the load path itself is covered by the same function via `init`.
final class MoveNetThunderModelTests: XCTestCase {

    /// The Thunder singlepose int8 variant's reported input shape is accepted.
    func testValidateInputShapeAcceptsThunderSingleposeInt8() throws {
        try MoveNetThunderModel.validateInputShape([1, 256, 256, 3])
    }

    /// Lightning's 192x192 variant still loads and allocates in TFLite — the check exists
    /// precisely to reject it, since a wrong variant would otherwise only show up as worse
    /// keypoints.
    func testValidateInputShapeRejectsLightningVariant() {
        XCTAssertThrowsError(try MoveNetThunderModel.validateInputShape([1, 192, 192, 3]))
    }

    func testValidateInputShapeRejectsWrongRank() {
        XCTAssertThrowsError(try MoveNetThunderModel.validateInputShape([256, 256, 3]))
    }

    func testValidateInputShapeRejectsWrongChannels() {
        XCTAssertThrowsError(try MoveNetThunderModel.validateInputShape([1, 256, 256, 1]))
    }

    /// The Thunder singlepose int8 variant's reported output shape is accepted.
    func testValidateOutputShapeAcceptsThunderSingleposeInt8() throws {
        try MoveNetThunderModel.validateOutputShape([1, 1, 17, 3])
    }

    /// A variant with a different output layout is rejected at load, before inference runs —
    /// the keypoint parser only counts 51 floats, so without this the wrong layout would
    /// surface only as silently worse keypoints.
    func testValidateOutputShapeRejectsWrongLayout() {
        XCTAssertThrowsError(try MoveNetThunderModel.validateOutputShape([1, 1, 17, 2]))
    }

    /// The failure must be the typed diagnostic error naming the expected shape, so the
    /// contributor sees *which* variant to fetch rather than a bare mismatch.
    func testValidateInputShapeErrorNamesTheExpectedShape() {
        XCTAssertThrowsError(try MoveNetThunderModel.validateInputShape([1, 192, 192, 3])) { error in
            guard case PoseDiagnosticError.inferenceFailed(let message) = error else {
                return XCTFail("expected PoseDiagnosticError.inferenceFailed, got \(error)")
            }
            XCTAssertTrue(
                message.contains("1, 256, 256, 3"),
                "error should name the expected shape: \(message)"
            )
            XCTAssertTrue(
                message.contains("[1, 192, 192, 3]"),
                "error should name the actual bundled shape: \(message)"
            )
        }
    }
}
