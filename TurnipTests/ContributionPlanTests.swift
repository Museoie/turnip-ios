import XCTest
@testable import Turnip

/// `ContributionPlan.init` pins (`docs/CONTRIBUTION_DESIGN.md` §2.3, §3.3, §8):
/// a clip marked as someone else is never sent, the first clip marked as the
/// user decides the sent person, every other person's clips stay behind as
/// `.otherPerson`, the 0.3 / 0.6 gap thresholds decide patchy / unusable, and
/// nothing is sent when the pose is unusable or absent.
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

    /// A clip marked as someone else is never sent, even of the same person
    /// as a clip marked as the user that is.
    func testAClipMarkedAsSomeoneElseIsNeverSent() throws {
        let items = [
            Self.clip(personID: 1, window: TrickWindow(startTime: 0, endTime: 0.5)),
            Self.clip(personID: 1, window: TrickWindow(startTime: 0.5, endTime: 1), isMe: false)
        ]
        let plan = ContributionPlan(clips: items, videoID: "video-1", duration: 2) { _ in
            Self.frames(at: (0..<20).map { TimeInterval($0) / 10 })
        }

        XCTAssertEqual(plan.clips.map { $0.status }, [.ready, .someoneElse])
        XCTAssertTrue(plan.hasReadyClips)
        let source = try XCTUnwrap(plan.source)
        XCTAssertEqual(source.clips.map { $0.clipID }, [items[0].id])
    }

    /// A first clip marked as someone else doesn't decide whose pose is sent:
    /// the first clip marked as the user does.
    func testTheFirstClipMarkedAsTheUserDecidesThePerson() throws {
        let items = [
            Self.clip(personID: 2, window: TrickWindow(startTime: 0, endTime: 0.5), isMe: false),
            Self.clip(personID: 1, window: TrickWindow(startTime: 0.5, endTime: 1))
        ]
        var requestedPerson: Int?
        let plan = ContributionPlan(clips: items, videoID: "video-1", duration: 2) { person in
            requestedPerson = person
            return Self.frames(at: (0..<20).map { TimeInterval($0) / 10 })
        }

        XCTAssertEqual(requestedPerson, 1)
        XCTAssertEqual(plan.clips.map { $0.status }, [.someoneElse, .ready])
        XCTAssertEqual(try XCTUnwrap(plan.source).clips.map { $0.clipID }, [items[1].id])
    }

    /// Only clips of someone else: nothing is sent and no pose is even read.
    func testOnlyClipsOfSomeoneElseSendNothing() {
        let items = [
            Self.clip(personID: nil, window: TrickWindow(startTime: 0, endTime: 0.9), isMe: false)
        ]
        var calls = 0
        let plan = ContributionPlan(clips: items, videoID: "video-1", duration: 1) { _ in
            calls += 1
            return Self.frames(at: (0..<10).map { TimeInterval($0) / 10 })
        }

        XCTAssertEqual(calls, 0)
        XCTAssertTrue(plan.hasClips)
        XCTAssertFalse(plan.hasReadyClips)
        XCTAssertEqual(plan.clips.map { $0.status }, [.someoneElse])
        XCTAssertNil(plan.source)
    }

    /// The sheet's Confirm stays disabled until the 16-or-older confirmation
    /// is set, whatever else holds.
    func testConfirmNeedsTheAgeConfirmation() {
        let sendable = Self.plan(framesAt: (0...9).map { TimeInterval($0) / 10 })
        XCTAssertNotNil(sendable.source)

        XCTAssertFalse(ContributionSheet.canConfirm(isSignedIn: true, plan: sendable, confirmsAge: false))
        XCTAssertTrue(ContributionSheet.canConfirm(isSignedIn: true, plan: sendable, confirmsAge: true))
        XCTAssertFalse(ContributionSheet.canConfirm(isSignedIn: false, plan: sendable, confirmsAge: true))
        let empty = ContributionPlan(clips: [], videoID: "video-1", duration: 1) { _ in [] }
        XCTAssertFalse(ContributionSheet.canConfirm(isSignedIn: true, plan: empty, confirmsAge: true))
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

    private static func clip(personID: Int?, window: TrickWindow, isMe: Bool = true) -> ClipListItem {
        ClipListItem(
            window: window,
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            personID: personID,
            isMe: isMe)
    }

    private static func frames(at times: [TimeInterval]) -> [PoseFrameResult] {
        times.enumerated().map { index, time in
            PoseFrameResult(
                frameIndex: index, timestamp: time,
                keypoints: PoseKeypoint.names.map { PoseKeypoint(name: $0, y: 0.4, x: 0.5, confidence: 0.9) })
        }
    }
}
