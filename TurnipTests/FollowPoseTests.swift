import CoreGraphics
import XCTest
@testable import Turnip

final class FollowPoseTests: XCTestCase {
    private let portrait = CGSize(width: 1080, height: 1920)

    /// An athlete 10% of the frame tall, sampled every 0.1 s at `indices`, standing at `x(index)`.
    private func athlete(_ indices: Range<Int>, x: (Int) -> Float) -> [PoseFrameResult] {
        indices.map { PoseFixture.frame(index: $0, hip: (x: x($0), y: 0.6), upperBody: (x: x($0), y: 0.5)) }
    }

    private func walking(_ index: Int) -> Float { 0.2 + 0.015 * Float(index) }

    /// A track that starts halfway through, the trim having pulled the window out past it, takes
    /// the first half from the surest pose in each frame, where that pose is the athlete, and
    /// keeps its own frames as they were.
    func testAPersonsTrackIsFilledBeforeItStarts() {
        let own = athlete(20..<40, x: walking)
        let surest = athlete(0..<40, x: walking)

        let filled = FollowPose.frames(of: own, borrowingFrom: [surest], renderedPixelSize: portrait)

        XCTAssertEqual(filled.map(\.frameIndex), surest.map(\.frameIndex))
        XCTAssertEqual(filled.map(\.timestamp), surest.map(\.timestamp))
        for (frame, expected) in zip(filled[..<20], surest[..<20]) {
            XCTAssertEqual(frame.keypoints, expected.keypoints, "at \(frame.timestamp) s")
        }
        XCTAssertEqual(Array(filled[20...]).map(\.keypoints), own.map(\.keypoints))
    }

    /// The same after the track ends, and in a frame inside it the tracker didn't see them in.
    func testAPersonsTrackIsFilledAfterItEndsAndWhereItMissedThem() {
        var own = athlete(0..<20, x: walking)
        own[10] = PoseFrameResult(frameIndex: own[10].frameIndex, timestamp: own[10].timestamp, keypoints: [])
        let surest = athlete(0..<40, x: walking)

        let filled = FollowPose.frames(of: own, borrowingFrom: [surest], renderedPixelSize: portrait)

        XCTAssertEqual(filled.count, 40)
        XCTAssertEqual(filled[10].keypoints, surest[10].keypoints)
        XCTAssertEqual(filled[39].keypoints, surest[39].keypoints)
    }

    /// Of two people in the other poses, both within reach, the one nearest where the athlete
    /// was last seen is followed, whichever is listed first. The bystander walks a tenth of the
    /// frame's width beside the athlete: about half a body size from where the athlete was a
    /// sample before, inside the 0.8 the reach allows, where the athlete is a twelfth of one.
    func testTheNearestPersonIsFollowed() {
        let own = athlete(20..<40, x: walking)
        let bystander = athlete(0..<20) { walking($0) + 0.1 }
        let surest = athlete(0..<20, x: walking)

        let filled = FollowPose.frames(of: own, borrowingFrom: [bystander, surest], renderedPixelSize: portrait)

        XCTAssertEqual(filled.count, 40)
        for index in 0..<20 {
            XCTAssertEqual(filled[index].keypoints, surest[index].keypoints, "at \(index)")
        }
    }

    /// Someone out of reach of where the athlete was last seen is not the athlete, and nothing is
    /// filled in. Here they are at the foot of the frame and the athlete at its head, eight of
    /// the athlete's 192 px heights apart, past the 6.5 the reach grows to over two seconds.
    func testSomeoneOutOfReachIsNotFollowed() {
        let own = (20..<40).map { PoseFixture.frame(index: $0, hip: (x: 0.5, y: 0.15), upperBody: (x: 0.5, y: 0.05)) }
        let bystander = (0..<20).map {
            PoseFixture.frame(index: $0, hip: (x: 0.5, y: 0.95), upperBody: (x: 0.5, y: 0.85))
        }

        let filled = FollowPose.frames(of: own, borrowingFrom: [bystander], renderedPixelSize: portrait)

        XCTAssertEqual(filled.map(\.frameIndex), own.map(\.frameIndex))
    }

    /// Past two seconds with nobody near, the walk stops: someone at the same spot later on is
    /// as likely to be someone else.
    func testTheWalkStopsAfterTwoSecondsWithoutASighting() {
        let own = athlete(40..<60, x: { _ in 0.5 })
        let surest = athlete(0..<15, x: { _ in 0.5 })

        let filled = FollowPose.frames(of: own, borrowingFrom: [surest], renderedPixelSize: portrait)

        XCTAssertEqual(filled.map(\.frameIndex), own.map(\.frameIndex))
    }

    /// A clip with no person, or a track that locates nothing, is left as it is.
    func testWithNothingToStartFromThePoseIsUnchanged() {
        let surest = athlete(0..<20, x: walking)
        let empty = (0..<10).map { PoseFrameResult(frameIndex: $0 * 3, timestamp: Double($0) / 10, keypoints: []) }

        XCTAssertEqual(
            FollowPose.frames(of: empty, borrowingFrom: [surest], renderedPixelSize: portrait).map(\.frameIndex),
            empty.map(\.frameIndex))
        XCTAssertEqual(
            FollowPose.frames(of: surest, borrowingFrom: [], renderedPixelSize: portrait).map(\.frameIndex),
            surest.map(\.frameIndex))
    }

    /// Filled in, Auto follow follows the athlete through the first half of the window rather
    /// than holding still at the framing of the track's first frame.
    func testAutoFollowMovesThroughTheFilledHalf() throws {
        let own = athlete(20..<40, x: walking)
        let surest = athlete(0..<40, x: walking)
        let frame = CGRect(origin: .zero, size: portrait)
        let window = TrickWindow(startTime: 0, endTime: 3.9)

        let alone = AutoFollow().defaultCrop(poseFrames: own, window: window, cropRect: frame, videoSize: portrait)
        let filled = AutoFollow().defaultCrop(
            poseFrames: FollowPose.frames(of: own, borrowingFrom: [surest], renderedPixelSize: portrait),
            window: window, cropRect: frame, videoSize: portrait)

        let early = alone.path.framing(at: 0.2).center.x, late = alone.path.framing(at: 1.6).center.x
        XCTAssertEqual(early, late, accuracy: 0.5, "alone, the crop holds until the track starts")
        XCTAssertLessThan(
            filled.path.framing(at: 0.2).center.x, filled.path.framing(at: 1.6).center.x - 50,
            "filled in, it follows the athlete across")
    }
}
