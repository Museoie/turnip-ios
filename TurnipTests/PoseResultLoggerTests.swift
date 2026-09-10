import XCTest
@testable import Turnip

final class PoseResultLoggerTests: XCTestCase {
    /// The bug in #35 was invisible to call-level assertions: both the redacted and the fixed
    /// shapes call the logger once with a correct-looking string. The assertion has to be on
    /// the digits in the emitted line itself.
    func testLineRendersConfidenceAndTimestampAsDigits() {
        let keypoints = PoseKeypoint.names.map { name in
            PoseKeypoint(name: name, y: 0.5, x: 0.5, confidence: 0.61)
        }
        let result = PoseFrameResult(frameIndex: 7, timestamp: 0.23, keypoints: keypoints)

        XCTAssertEqual(
            PoseResultLogger.line(for: result),
            "frame 7 t=0.23s avgConfidence=0.61 usableKeypoints=17/17"
        )
    }

    func testLineRendersEmptyResultAsZeroesNotRedacted() {
        let result = PoseFrameResult(frameIndex: 0, timestamp: 0, keypoints: [])

        let line = PoseResultLogger.line(for: result)

        XCTAssertEqual(line, "frame 0 t=0.00s avgConfidence=0.00 usableKeypoints=0/17")
        XCTAssertFalse(line.contains("<private>"))
    }
}
