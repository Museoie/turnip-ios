import XCTest
@testable import Turnip

final class PoseKeypointParsingTests: XCTestCase {
    /// 17 keypoints x (y, x, score), with distinct values so we can catch an accidental
    /// y/x swap — a well-known MoveNet integration bug.
    private func makeRawValues() -> [Float] {
        (0..<17).flatMap { index -> [Float] in
            let base = Float(index)
            return [base + 0.1, base + 0.2, base + 0.3] // y, x, score
        }
    }

    func testParseProducesSeventeenKeypointsInOrderWithYBeforeX() throws {
        let keypoints = try PoseKeypoint.parse(from: makeRawValues())

        XCTAssertEqual(keypoints.count, PoseKeypoint.names.count)

        for (index, keypoint) in keypoints.enumerated() {
            let base = Float(index)
            XCTAssertEqual(keypoint.name, PoseKeypoint.names[index])
            XCTAssertEqual(keypoint.y, base + 0.1, accuracy: 0.0001)
            XCTAssertEqual(keypoint.x, base + 0.2, accuracy: 0.0001)
            XCTAssertEqual(keypoint.confidence, base + 0.3, accuracy: 0.0001)
        }
    }

    func testUsableKeypointCountExcludesLowConfidence() throws {
        var values = [Float](repeating: 0, count: 51)
        // Keypoint 0: confidence above threshold. Keypoint 1: below threshold.
        values[2] = 0.9
        values[5] = 0.1

        let keypoints = try PoseKeypoint.parse(from: values)
        let result = PoseFrameResult(frameIndex: 0, timestamp: 0, keypoints: keypoints)

        XCTAssertEqual(result.usableKeypointCount, 1)
    }

    func testParseThrowsOnMalformedInput() {
        let tooShort: [Float] = [0.1, 0.2, 0.3]

        XCTAssertThrowsError(try PoseKeypoint.parse(from: tooShort)) { error in
            XCTAssertTrue(error is PoseError)
        }
    }
}
