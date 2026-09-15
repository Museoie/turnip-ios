import XCTest
@testable import Turnip

/// `MoveNetThunderModel.validateShape` is pure so it can be exercised without the
/// gitignored `.tflite` — the load path itself is covered by the same function via `init`.
final class MoveNetThunderModelTests: XCTestCase {

    /// The Thunder singlepose int8 variant's reported input shape is accepted.
    func testValidateInputShapeAcceptsThunderSingleposeInt8() throws {
        try MoveNetThunderModel.validateShape(
            [1, 256, 256, 3], expected: MoveNetThunderModel.expectedInputShape, named: "input"
        )
    }

    /// Lightning's 192x192 variant still loads and allocates in TFLite — the check exists
    /// precisely to reject it, since a wrong variant would otherwise only show up as worse
    /// keypoints.
    func testValidateInputShapeRejectsLightningVariant() {
        XCTAssertThrowsError(
            try MoveNetThunderModel.validateShape(
                [1, 192, 192, 3], expected: MoveNetThunderModel.expectedInputShape, named: "input"
            )
        )
    }

    func testValidateInputShapeRejectsWrongRank() {
        XCTAssertThrowsError(
            try MoveNetThunderModel.validateShape(
                [256, 256, 3], expected: MoveNetThunderModel.expectedInputShape, named: "input"
            )
        )
    }

    func testValidateInputShapeRejectsWrongChannels() {
        XCTAssertThrowsError(
            try MoveNetThunderModel.validateShape(
                [1, 256, 256, 1], expected: MoveNetThunderModel.expectedInputShape, named: "input"
            )
        )
    }

    /// The Thunder singlepose int8 variant's reported output shape is accepted.
    func testValidateOutputShapeAcceptsThunderSingleposeInt8() throws {
        try MoveNetThunderModel.validateShape(
            [1, 1, 17, 3], expected: MoveNetThunderModel.expectedOutputShape, named: "output"
        )
    }

    /// A variant with a different output layout is rejected at load, before inference runs —
    /// the keypoint parser only counts 51 floats, so without this the wrong layout would
    /// surface only as silently worse keypoints.
    func testValidateOutputShapeRejectsWrongLayout() {
        XCTAssertThrowsError(
            try MoveNetThunderModel.validateShape(
                [1, 1, 17, 2], expected: MoveNetThunderModel.expectedOutputShape, named: "output"
            )
        )
    }

    /// The failure must be the typed wrong-variant error naming the expected shape, so the
    /// contributor sees *which* variant to fetch rather than a bare mismatch — and so
    /// `load()` can evict a bad staged record without dropping a good one on a transient
    /// load failure.
    func testValidateInputShapeErrorNamesTheExpectedShape() {
        XCTAssertThrowsError(
            try MoveNetThunderModel.validateShape(
                [1, 192, 192, 3], expected: MoveNetThunderModel.expectedInputShape, named: "input"
            )
        ) { error in
            guard case PoseError.wrongModelVariant(let message) = error else {
                return XCTFail("expected PoseError.wrongModelVariant, got \(error)")
            }
            XCTAssertTrue(
                message.contains("[1, 256, 256, 3]"),
                "error should name the expected shape: \(message)"
            )
            XCTAssertTrue(
                message.contains("[1, 192, 192, 3]"),
                "error should name the actual bundled shape: \(message)"
            )
        }
    }

    // MARK: - resolveModelPath version floor

    /// A malformed staged version must not shadow the bundled model, even when
    /// `ModelVersion.<`'s lexicographic fallback would rank it newer than the
    /// bundled `"1"` — this is the defense-in-depth gate the manifest-validation
    /// service can't guarantee for store records written before it existed.
    func testResolveModelPathRejectsMalformedStagedVersion() {
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: "/bundled/movenet.tflite",
                stagedVersion: ModelVersion("v2"),
                stagedPath: "/staged/movenet.tflite"
            ),
            "/bundled/movenet.tflite"
        )
    }

    /// A malformed staged version with no bundled model to fall back to yields
    /// no candidate — `load()` then reports `modelNotFound` instead of
    /// pointing the loader at the untrusted file.
    func testResolveModelPathRejectsMalformedStagedVersionWithoutBundled() {
        XCTAssertNil(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: nil,
                stagedVersion: ModelVersion("v2"),
                stagedPath: "/staged/movenet.tflite"
            )
        )
    }

    /// A well-formed staged version newer than the bundled one still shadows it.
    func testResolveModelPathPrefersNewerWellFormedStagedVersion() {
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: "/bundled/movenet.tflite",
                stagedVersion: ModelVersion("2"),
                stagedPath: "/staged/movenet.tflite"
            ),
            "/staged/movenet.tflite"
        )
    }

    /// A well-formed but older-or-equal staged version doesn't shadow the bundled one.
    func testResolveModelPathKeepsBundledWhenStagedVersionIsOlder() {
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: "/bundled/movenet.tflite",
                stagedVersion: ModelVersion("0.9"),
                stagedPath: "/staged/movenet.tflite"
            ),
            "/bundled/movenet.tflite"
        )
    }

    /// No staged version leaves the bundled model as the candidate.
    func testResolveModelPathKeepsBundledWithoutStagedVersion() {
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: "/bundled/movenet.tflite",
                stagedVersion: nil,
                stagedPath: nil
            ),
            "/bundled/movenet.tflite"
        )
    }
}
