import Foundation
import XCTest
@testable import Turnip

/// The packed form drops the per-keypoint identity and labels and keeps only the numbers,
/// in COCO order — so a round-trip must restore the values exactly, and nothing else.
final class PackedPoseFrameTests: XCTestCase {
    func testPackUnpackRestoresAWholeBodyFrame() {
        let frame = MultiPoseFrame(single: PoseFixture.body(index: 2, hip: (x: 0.5, y: 0.4)))
        let unpacked = PackedPoseFrame(frame).unpack()

        XCTAssertEqual(unpacked.frameIndex, frame.frameIndex)
        XCTAssertEqual(unpacked.timestamp, frame.timestamp)
        XCTAssertEqual(unpacked.people.count, 1)
        XCTAssertEqual(unpacked.people[0].score, frame.people[0].score)
        XCTAssertEqual(unpacked.people[0].box, frame.people[0].box)
        // Names come back from the joint index, not from the stored frame.
        XCTAssertEqual(
            unpacked.primary.keypoints.map(\.name), frame.primary.keypoints.map(\.name))
        assertSameKeypoints(unpacked.primary.keypoints, frame.primary.keypoints)
    }

    func testPackUnpackRestoresEveryPersonInOrder() {
        let people = (0..<6).map { index in
            DetectedPerson.fixture(
                [PoseKeypoint(name: "nose", y: 0.1 * Float(index), x: 0.2, confidence: 0.9)],
                score: 0.9 - Float(index) * 0.1)
        }
        let frame = MultiPoseFrame(frameIndex: 7, timestamp: 0.7, people: people)
        let unpacked = PackedPoseFrame(frame).unpack()

        XCTAssertEqual(unpacked.people.count, 6)
        XCTAssertEqual(unpacked.people.map(\.score), people.map(\.score))
        for (got, want) in zip(unpacked.people, people) {
            assertSameKeypoints(got.keypoints, want.keypoints)
        }
        // The primary is re-derived from the most-confident person, as the rich frame does.
        XCTAssertEqual(unpacked.primary.keypoints.map(\.name), ["nose"])
    }

    func testPackUnpackRestoresASingleKeypointPerson() {
        // The drain's own fixture shape: one joint, not seventeen.
        let single = DetectedPerson.fixture(
            [PoseKeypoint(name: "nose", y: 0.2, x: 0.1, confidence: 0.9)])
        let frameWithSingle = MultiPoseFrame(frameIndex: 0, timestamp: 0, people: [single])

        let unpacked = PackedPoseFrame(frameWithSingle).unpack()

        XCTAssertEqual(unpacked.people.count, 1)
        XCTAssertEqual(unpacked.people[0].keypoints.count, 1)
        XCTAssertEqual(unpacked.people[0].keypoints[0].name, "nose")
        assertSameKeypoints(unpacked.people[0].keypoints, single.keypoints)
    }

    func testPackUnpackRestoresAnEmptyFrame() {
        let frame = MultiPoseFrame(frameIndex: 8, timestamp: 0.8, people: [])
        let unpacked = PackedPoseFrame(frame).unpack()

        XCTAssertEqual(unpacked.frameIndex, 8)
        XCTAssertEqual(unpacked.timestamp, 0.8)
        XCTAssertTrue(unpacked.people.isEmpty)
    }

    func testPackedPersonCarriesThreeFloatsPerJointAndNothingElse() {
        let person = DetectedPerson.fixture(PoseFixture.body(index: 0, hip: (x: 0.5, y: 0.5)).keypoints)
        let packed = PackedPosePerson(person)

        XCTAssertEqual(packed.keypoints.count, PoseKeypoint.names.count * 3)
        XCTAssertEqual(packed.keypoints[0], person.keypoints[0].y, "y first, then x, then confidence")
        XCTAssertEqual(packed.keypoints[1], person.keypoints[0].x)
        XCTAssertEqual(packed.keypoints[2], person.keypoints[0].confidence)
    }

    /// Compares keypoints by value — y, x, confidence — not by identity: unpacking mints
    /// fresh ids, by design.
    private func assertSameKeypoints(_ lhs: [PoseKeypoint], _ rhs: [PoseKeypoint]) {
        XCTAssertEqual(lhs.map { [$0.y, $0.x, $0.confidence] }, rhs.map { [$0.y, $0.x, $0.confidence] })
    }
}
