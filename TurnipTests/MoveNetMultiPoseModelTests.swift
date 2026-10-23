import XCTest
@testable import Turnip

/// `MoveNetMultiPoseModel.validateShape` is pure so it can be exercised without the
/// gitignored `.tflite` — the load path itself is covered by the same function via `init`.
final class MoveNetMultiPoseModelTests: XCTestCase {

    /// MultiPose's reported output shape, six people of 56 values each, is accepted.
    func testValidateOutputShapeAcceptsMultiPose() throws {
        try MoveNetMultiPoseModel.validateShape(
            [1, 6, 56], expected: MoveNetMultiPoseModel.expectedOutputShape, named: "output"
        )
    }

    /// A single-pose MoveNet takes the same resize, allocates and runs, so the output shape is
    /// what tells it apart at load — without this a Thunder or Lightning file would fail only
    /// in the parse, on the first frame.
    func testValidateOutputShapeRejectsASinglePoseModel() {
        XCTAssertThrowsError(
            try MoveNetMultiPoseModel.validateShape(
                [1, 1, 17, 3], expected: MoveNetMultiPoseModel.expectedOutputShape, named: "output"
            )
        )
    }

    /// The failure must be the typed `PoseError` naming the expected shape, so the
    /// contributor sees *which* model to fetch rather than a bare mismatch.
    func testValidateOutputShapeErrorNamesBothShapes() {
        XCTAssertThrowsError(
            try MoveNetMultiPoseModel.validateShape(
                [1, 1, 17, 3], expected: MoveNetMultiPoseModel.expectedOutputShape, named: "output"
            )
        ) { error in
            guard case PoseError.inferenceFailed(let message) = error else {
                return XCTFail("expected PoseError.inferenceFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("[1, 6, 56]"), "error should name the expected shape: \(message)")
            XCTAssertTrue(message.contains("[1, 1, 17, 3]"), "error should name the bundled shape: \(message)")
        }
    }
}
