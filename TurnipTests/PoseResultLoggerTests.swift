import XCTest
@testable import Turnip

final class PoseResultLoggerTests: XCTestCase {
    func testLineRendersConfidenceAndTimestamp() {
        let keypoints = PoseKeypoint.names.map { name in
            PoseKeypoint(name: name, y: 0.5, x: 0.5, confidence: 0.61)
        }
        let result = PoseFrameResult(frameIndex: 7, timestamp: 0.23, keypoints: keypoints)

        XCTAssertEqual(
            PoseResultLogger.line(for: result),
            "frame 7 t=0.23s avgConfidence=0.61 usableKeypoints=17/\(PoseKeypoint.names.count)"
        )
    }

    func testLineRendersEmptyResultAsZeroes() {
        let result = PoseFrameResult(frameIndex: 0, timestamp: 0, keypoints: [])

        let line = PoseResultLogger.line(for: result)

        XCTAssertEqual(line, "frame 0 t=0.00s avgConfidence=0.00 usableKeypoints=0/\(PoseKeypoint.names.count)")
    }
}
