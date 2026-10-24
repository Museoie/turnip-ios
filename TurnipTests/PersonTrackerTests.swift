import XCTest
@testable import Turnip

/// `PersonTracker` links each frame's people into people followed across the take. Standing
/// bodies from `PoseFixture` are 0.1 wide and about 0.33 tall, so in a 1000×1000 frame a body
/// size is about 330 pixels.
final class PersonTrackerTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 1000)

    func testTwoPeopleStandingApartAreTwoTracksThatKeepTheirOwnPoses() {
        let frames = (0..<10).map { index in
            frame(index, [person(index, x: 0.2), person(index, x: 0.7)])
        }

        let tracks = PersonTracker().tracks(in: frames, renderedPixelSize: size)

        XCTAssertEqual(tracks.map(\.frames.count), [10, 10])
        XCTAssertEqual(hipXs(tracks[0]), Array(repeating: 0.2, count: 10))
        XCTAssertEqual(hipXs(tracks[1]), Array(repeating: 0.7, count: 10))
    }

    /// The model lists people in whatever order it likes; a person's track follows the person.
    func testTheOrderTheModelListsPeopleInDoesNotSwapTracks() {
        let frames = (0..<10).map { index in
            let left = person(index, x: 0.2)
            let right = person(index, x: 0.7)
            return frame(index, index.isMultiple(of: 2) ? [left, right] : [right, left])
        }

        let tracks = PersonTracker().tracks(in: frames, renderedPixelSize: size)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(hipXs(tracks[0]), Array(repeating: 0.2, count: 10))
        XCTAssertEqual(hipXs(tracks[1]), Array(repeating: 0.7, count: 10))
    }

    /// Lost for half a second and found 500 px (1.5 body sizes) further on, with no overlap
    /// left between the boxes: within reach (0.5 + 3 × 0.5 = 2 body sizes), so the same person.
    /// The frames they were lost in stay in the track, with no pose.
    func testSomeoneLostBrieflyAndFoundFurtherOnStaysOneTrack() {
        let frames = (0..<10).map { index -> MultiPoseFrame in
            switch index {
            case 0...4: return frame(index, [person(index, x: 0.3)])
            case 9: return frame(index, [person(index, x: 0.8)])
            default: return frame(index, [])
            }
        }

        let tracks = PersonTracker().tracks(in: frames, renderedPixelSize: size)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].frames.map(\.timestamp), frames.map(\.timestamp))
        XCTAssertEqual(
            tracks[0].frames.map(\.keypoints.isEmpty),
            [false, false, false, false, false, true, true, true, true, false])
    }

    /// Gone for longer than the one-second gap, they come back as someone new, even in the same
    /// spot: telling a returning person from another arriving there is beyond position alone.
    func testSomeoneGoneLongerThanTheGapComesBackAsANewTrack() {
        let frames = (0..<17).map { index in
            frame(index, index <= 4 || index == 16 ? [person(index, x: 0.5)] : [])
        }

        let tracks = PersonTracker().tracks(in: frames, renderedPixelSize: size)

        XCTAssertEqual(tracks.map(\.frames.count), [5, 1])
    }

    /// Someone appearing 800 px (about 2.4 body sizes) from where the only other person vanished
    /// a tenth of a second earlier is out of reach (0.5 + 3 × 0.1 = 0.8): a new person.
    func testSomeoneAppearingOutOfReachIsANewTrack() {
        let frames = (0..<10).map { index in
            frame(index, [person(index, x: index < 5 ? 0.1 : 0.9)])
        }

        let tracks = PersonTracker().tracks(in: frames, renderedPixelSize: size)

        XCTAssertEqual(tracks.map(\.frames.count), [5, 5])
        XCTAssertEqual(tracks[1].frames.first?.timestamp ?? -1, 0.5, accuracy: 1e-9)
    }

    // MARK: - Fixtures

    private func person(_ index: Int, x: Float, y: Float = 0.5) -> DetectedPerson {
        .fixture(PoseFixture.body(index: index, hip: (x: x, y: y)).keypoints)
    }

    private func frame(_ index: Int, _ people: [DetectedPerson]) -> MultiPoseFrame {
        MultiPoseFrame(frameIndex: index * 3, timestamp: Double(index) * PoseFixture.frameInterval, people: people)
    }

    /// The hip midpoint's x in each frame the person was seen in, rounded to keep float noise out.
    private func hipXs(_ track: PoseTrack) -> [Float] {
        track.frames.compactMap { frame in
            let hips = frame.keypoints.filter { $0.name.hasSuffix("_hip") }
            guard hips.count == 2 else { return nil }
            return ((hips[0].x + hips[1].x) / 2 * 100).rounded() / 100
        }
    }
}
