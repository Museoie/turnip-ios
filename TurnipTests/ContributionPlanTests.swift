import XCTest
@testable import Turnip

/// `ContributionPlan.init` pins (`docs/CONTRIBUTION_DESIGN.md` §2.3, §3.3):
/// the first clip's person is the sent person, every other person's clips stay
/// behind as `.otherPerson`, the 0.3 / 0.6 gap thresholds decide patchy /
/// unusable, and nothing is sent when the pose is unusable or absent.
final class ContributionPlanTests: XCTestCase {
    /// The first clip's person wins even when another person has more clips:
    /// their pose is requested, their clips are the only ones sent, and the
    /// rest are marked `.otherPerson`.
    func testFirstPersonsClipsAreSentAndOtherPersonsStayBehind() throws {
        let items = [
            Self.clip(personID: 1, window: TrickWindow(startTime: 0, endTime: 0.5)),
            Self.clip(personID: 2, window: TrickWindow(startTime: 0.5, endTime: 1)),
            Self.clip(personID: 2, window: TrickWindow(startTime: 1, endTime: 1.5)),
            Self.clip(personID: 2, window: TrickWindow(startTime: 1.5, endTime: 2))
        ]
        var requestedPerson: Int?
        var calls = 0
        let plan = ContributionPlan(clips: items, videoID: "video-1", duration: 2) { person in
            calls += 1
            requestedPerson = person
            return Self.frames(at: (0..<20).map { TimeInterval($0) / 10 })
        }

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(requestedPerson, 1)
        XCTAssertEqual(plan.clips.map { $0.status }, [.ready, .otherPerson, .otherPerson, .otherPerson])
        XCTAssertEqual(plan.quality, .good)
        let source = try XCTUnwrap(plan.source)
        XCTAssertEqual(source.videoID, "video-1")
        XCTAssertEqual(source.clips.map { $0.clipID }, [items[0].id])
    }

    /// Exactly 30% gaps is still good: the patchy threshold is *over* 30%.
    /// Seven frames over a ten-slot window leave three gaps.
    func testGapFractionAtPatchyBoundaryIsGood() throws {
        let plan = Self.plan(framesAt: (0...6).map { TimeInterval($0) / 10 })
        XCTAssertEqual(plan.quality, .good)
        XCTAssertNotNil(plan.source)
    }

    /// Four gaps over ten slots is 40%: patchy, so the clips are sent with a warning.
    func testGapFractionAbovePatchyBoundaryIsPatchy() throws {
        let plan = Self.plan(framesAt: (0...5).map { TimeInterval($0) / 10 })
        XCTAssertEqual(plan.quality, .patchy)
        XCTAssertNotNil(plan.source)
    }

    /// Exactly 60% gaps is still patchy: the unusable threshold is *over* 60%.
    func testGapFractionAtUnusableBoundaryIsPatchy() throws {
        let plan = Self.plan(framesAt: (0...3).map { TimeInterval($0) / 10 })
        XCTAssertEqual(plan.quality, .patchy)
        XCTAssertNotNil(plan.source)
    }

    /// Seven gaps over ten slots is 70%: unusable, so nothing is sent.
    func testGapFractionAboveUnusableBoundarySendsNothing() {
        let plan = Self.plan(framesAt: (0...2).map { TimeInterval($0) / 10 })
        XCTAssertEqual(plan.quality, .unusable)
        XCTAssertNil(plan.source)
    }

    /// No pose at all: unusable, nothing sent — but the clips are still
    /// described, so the sheet can say why.
    func testNoPoseAtAllSendsNothing() {
        let plan = ContributionPlan(
            clips: [Self.clip(personID: 1, window: TrickWindow(startTime: 0, endTime: 0.9))],
            videoID: "video-1", duration: 1) { _ in [] }
        XCTAssertEqual(plan.clips.map { $0.status }, [.ready])
        XCTAssertEqual(plan.quality, .unusable)
        XCTAssertNil(plan.source)
    }

    /// No clips: unusable, nothing sent.
    func testEmptyClipListSendsNothing() {
        let plan = ContributionPlan(clips: [], videoID: "video-1", duration: 1) { _ in [] }
        XCTAssertFalse(plan.hasClips)
        XCTAssertEqual(plan.quality, .unusable)
        XCTAssertNil(plan.source)
    }

    /// One ready clip over a ten-slot window, so the gap fraction is the
    /// share of its ten slots with no frame.
    private static func plan(framesAt times: [TimeInterval]) -> ContributionPlan {
        ContributionPlan(
            clips: [clip(personID: nil, window: TrickWindow(startTime: 0, endTime: 0.9))],
            videoID: "video-1", duration: 1) { _ in frames(at: times) }
    }

    private static func clip(personID: Int?, window: TrickWindow) -> ClipListItem {
        ClipListItem(
            window: window,
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            personID: personID)
    }

    private static func frames(at times: [TimeInterval]) -> [PoseFrameResult] {
        times.enumerated().map { index, time in
            PoseFrameResult(
                frameIndex: index, timestamp: time,
                keypoints: PoseKeypoint.names.map { PoseKeypoint(name: $0, y: 0.4, x: 0.5, confidence: 0.9) })
        }
    }
}
