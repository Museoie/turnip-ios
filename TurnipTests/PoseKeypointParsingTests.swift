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

final class DetectedPersonParsingTests: XCTestCase {
    /// Six people's worth of values, each scored `scores[index]`, with every value distinct so a
    /// swapped field shows: keypoint `k` of person `p` is (y, x, score) =
    /// (p + k / 100, p + k / 100 + 0.001, 0.5) and the box is (ymin, xmin, ymax, xmax) =
    /// (p + 0.1, p + 0.2, p + 0.3, p + 0.4).
    private func makeRawValues(scores: [Float]) -> [Float] {
        scores.enumerated().flatMap { person, score -> [Float] in
            let base = Float(person)
            let keypoints = (0..<17).flatMap { index -> [Float] in
                let value = base + Float(index) / 100
                return [value, value + 0.001, 0.5]
            }
            return keypoints + [base + 0.1, base + 0.2, base + 0.3, base + 0.4, score]
        }
    }

    func testParseKeepsOnlyPeopleAtOrAboveTheMinimumScoreInModelOrder() throws {
        let people = try DetectedPerson.parse(from: makeRawValues(scores: [0.6, 0.1, 0.25, 0, 0.9, 0.24]))

        XCTAssertEqual(people.map(\.score), [0.6, 0.25, 0.9])
    }

    /// The box is y-first like the keypoints: (ymin, xmin, ymax, xmax).
    func testParseReadsTheBoxYFirst() throws {
        let people = try DetectedPerson.parse(from: makeRawValues(scores: [0, 0.8, 0, 0, 0, 0]))

        let box = try XCTUnwrap(people.first).box
        XCTAssertEqual(box.minY, 1.1, accuracy: 0.0001)
        XCTAssertEqual(box.minX, 1.2, accuracy: 0.0001)
        XCTAssertEqual(box.maxY, 1.3, accuracy: 0.0001)
        XCTAssertEqual(box.maxX, 1.4, accuracy: 0.0001)
    }

    func testParseReadsEachPersonsOwnKeypointsInCOCOOrder() throws {
        let people = try DetectedPerson.parse(from: makeRawValues(scores: [0, 0, 0.8, 0, 0, 0]))

        let keypoints = try XCTUnwrap(people.first).keypoints
        XCTAssertEqual(keypoints.map(\.name), PoseKeypoint.names)
        XCTAssertEqual(keypoints[16].y, 2.16, accuracy: 0.0001)
        XCTAssertEqual(keypoints[16].x, 2.161, accuracy: 0.0001)
        XCTAssertEqual(keypoints[16].confidence, 0.5, accuracy: 0.0001)
    }

    func testParseThrowsOnASinglePoseOutput() {
        XCTAssertThrowsError(try DetectedPerson.parse(from: [Float](repeating: 0, count: 51))) { error in
            XCTAssertTrue(error is PoseError)
        }
    }

    func testMostConfidentKeypointsAreThoseOfTheHighestScoringPerson() throws {
        let people = try DetectedPerson.parse(from: makeRawValues(scores: [0.4, 0.9, 0.7, 0, 0, 0]))

        XCTAssertEqual(people.mostConfidentKeypoints.first?.y ?? .nan, 1.0, accuracy: 0.0001)
    }

    /// Nobody found reads as no pose, which every consumer already treats as nothing located.
    func testMostConfidentKeypointsAreEmptyWhenNobodyWasFound() {
        XCTAssertEqual([DetectedPerson]().mostConfidentKeypoints, [])
    }
}
