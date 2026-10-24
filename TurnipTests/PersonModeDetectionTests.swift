import XCTest
@testable import Turnip

/// `ProcessingPipeline.detect` in each person mode. The athlete is the single-peak fixture the
/// pipeline tests use (a vertical slide at x 0.65); a bystander stands still at x 0.2 the whole
/// take, and the model is surer of the bystander.
final class PersonModeDetectionTests: XCTestCase {
    private let size = CGSize(width: 1080, height: 1920)
    private let pipeline = ProcessingPipeline()

    /// Following one person follows whoever the model is surest of in each frame: here the
    /// bystander, who never moves, so nothing is found.
    func testFollowingOnePersonFollowsWhoeverTheModelIsSurestOf() {
        let frames = athleteAndBystander()

        let detection = pipeline.detect(in: frames, people: .one, renderedPixelSize: size)

        XCTAssertTrue(detection.clips.isEmpty)
        XCTAssertTrue(detection.people.isEmpty)
        XCTAssertEqual(detection.poseFrames, frames.map(\.primary))
    }

    /// Following everyone measures each person against their own activity: the athlete's trick
    /// is found though the model was surer of the bystander, it belongs to the athlete, and its
    /// crop is fitted to the athlete alone. The bystander owns no clip, so isn't kept.
    func testFollowingEveryoneGivesTheAthleteTheirOwnClip() throws {
        let frames = athleteAndBystander()

        let detection = pipeline.detect(in: frames, people: .everyone, renderedPixelSize: size)

        let clip = try XCTUnwrap(detection.clips.first)
        XCTAssertEqual(detection.clips.count, 1)
        XCTAssertEqual(detection.people.count, 1)
        XCTAssertEqual(clip.personID, detection.people.first?.id)
        let athlete = detection.poseFrames(forPerson: clip.personID)
        XCTAssertEqual(athlete.count, frames.count)
        XCTAssertTrue(
            athlete.allSatisfy { frame in frame.keypoints.allSatisfy { abs($0.x - 0.65) < 0.1 } },
            "the clip's frames are the athlete's, not the bystander's")
        let inWindow = athlete.filter { $0.timestamp >= clip.window.startTime && $0.timestamp <= clip.window.endTime }
        XCTAssertEqual(clip.cropRect, CropRectCalculator().cropRect(for: inWindow, renderedPixelSize: size))
    }

    /// Two people tricking in turn get a clip each, their own person on each, in start order.
    func testTwoPeopleTrickingInTurnEachGetTheirOwnClipInStartOrder() {
        let first = slide(startingAt: 10)
        let second = slide(startingAt: 40)
        let frames = (0..<60).map { index in
            MultiPoseFrame(
                frameIndex: index * 3, timestamp: Double(index) * PoseFixture.frameInterval,
                people: [
                    .fixture(PoseFixture.body(index: index, hip: (x: 0.75, y: second[index])).keypoints),
                    .fixture(PoseFixture.body(index: index, hip: (x: 0.25, y: first[index])).keypoints)
                ])
        }

        let detection = pipeline.detect(in: frames, people: .everyone, renderedPixelSize: size)

        XCTAssertEqual(detection.clips.count, 2)
        XCTAssertEqual(detection.people.count, 2)
        XCTAssertLessThan(detection.clips[0].window.startTime, detection.clips[1].window.startTime)
        XCTAssertNotEqual(detection.clips[0].personID, detection.clips[1].personID)
        let firstClipHips = detection.poseFrames(forPerson: detection.clips[0].personID)
            .flatMap(\.keypoints).map(\.x)
        XCTAssertTrue(firstClipHips.allSatisfy { abs($0 - 0.25) < 0.1 }, "the earlier trick is the left person's")
    }

    func testAClipWithoutAPersonReadsEveryScoredFrame() {
        let frames = athleteAndBystander().map(\.primary)
        let detection = DetectedClips(clips: [], poseFrames: frames, people: [PoseTrack(id: 3, frames: [])])

        XCTAssertEqual(detection.poseFrames(forPerson: nil), frames)
        XCTAssertEqual(detection.poseFrames(forPerson: 7), frames, "an unknown person falls back too")
        XCTAssertEqual(detection.poseFrames(forPerson: 3), [])
    }

    // MARK: - Fixtures

    private func athleteAndBystander() -> [MultiPoseFrame] {
        let athlete = PoseFixture.slide(quietFrames: 15, from: 0.2, perFrame: 0.1, movingFrames: 6, tailFrames: 14)
        return athlete.enumerated().map { index, y in
            MultiPoseFrame(
                frameIndex: index * 3, timestamp: Double(index) * PoseFixture.frameInterval,
                people: [
                    .fixture(PoseFixture.body(index: index, hip: (x: 0.2, y: 0.5)).keypoints, score: 0.95),
                    .fixture(PoseFixture.body(index: index, hip: (x: 0.65, y: y)).keypoints, score: 0.8)
                ])
        }
    }

    /// Hip heights for a 60-frame take: still at 0.2, a six-frame slide down starting at
    /// `start`, then still at the bottom.
    private func slide(startingAt start: Int) -> [Float] {
        PoseFixture.slide(quietFrames: start, from: 0.2, perFrame: 0.1, movingFrames: 6, tailFrames: 60 - start - 6)
    }
}
