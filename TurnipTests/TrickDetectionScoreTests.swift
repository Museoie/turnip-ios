import XCTest
@testable import Turnip

final class TrickDetectionScoreTests: XCTestCase {
    private let trick: ClosedRange<TimeInterval> = 7.3...10.5
    private let leftHalf = NormalizedRect(minX: 0, maxX: 0.5, minY: 0, maxY: 1)
    private let rightHalf = NormalizedRect(minX: 0.5, maxX: 1, minY: 0, maxY: 1)

    func testAClipCoveringMostOfATrickCatchesIt() {
        let score = TrickDetectionScore(windows: [window(6.9, 11.9)], tricks: [trick])

        XCTAssertEqual(score.outcomes, [.caught])
        XCTAssertEqual(score.falsePositives, 0)
    }

    /// A clip that opens 1.6 s into a 3.2 s trick holds half of it: the user gets the landing
    /// without the take-off.
    func testAClipThatStartsLateOnlyPartlyCatchesTheTrick() {
        let score = TrickDetectionScore(windows: [window(8.9, 13.6)], tricks: [trick])

        XCTAssertEqual(score.outcomes, [.partial])
    }

    func testCoverageAtExactlyTheThresholdCatches() {
        // 80% of the 3.2 s trick is 2.56 s.
        let score = TrickDetectionScore(windows: [window(7.3 + 0.64, 12)], tricks: [trick])

        XCTAssertEqual(score.outcomes, [.caught])
    }

    /// Two clips that each hold half the trick are two partial clips, not one caught trick.
    func testCoverageIsPerClipNotTheUnionOfClips() {
        let score = TrickDetectionScore(windows: [window(7, 8.9), window(8.9, 11)], tricks: [trick])

        XCTAssertEqual(score.outcomes, [.partial])
    }

    func testATrickNoClipTouchesIsMissed() {
        let score = TrickDetectionScore(windows: [], tricks: [trick])

        XCTAssertEqual(score.outcomes, [.missed])
        XCTAssertEqual(score.clipSeconds, 0)
    }

    func testAClipTouchingNoTrickIsAFalsePositive() {
        let score = TrickDetectionScore(windows: [window(1.7, 6.0), window(9, 12)], tricks: [trick])

        XCTAssertEqual(score.falsePositives, 1)
        XCTAssertEqual(score.clipSeconds, 4.3 + 3, accuracy: 1e-9)
    }

    /// The shipped detector's IMG_4639 windows against that clip's labels, as the investigation
    /// that built this scorer scored them — pins the rules to the numbers it reported.
    func testReproducesAKnownScore() {
        let windows = [window(1.7, 6.0), window(8.9, 13.6), window(15.3, 20.8), window(30.9, 35.8), window(36.2, 44.9)]
        let tricks: [ClosedRange<TimeInterval>] = [7.3...10.5, 14.5...17.0, 24.0...26.3, 30.7...33.0, 36.3...39.7]

        let score = TrickDetectionScore(windows: windows, tricks: tricks)

        XCTAssertEqual(score.summary, "PPMCC+1fp+0dup")
    }

    func testATrickTwoClipsTouchIsOneDuplicate() {
        let score = TrickDetectionScore(windows: [window(7, 8.9), window(8.9, 11)], tricks: [trick])

        XCTAssertEqual(score.duplicates, 1)
        XCTAssertEqual(score.summary, "P+0fp+1dup")
    }

    /// A caught trick is still a duplicate when a second clip, of the same person or another,
    /// covers it too: the user gets two clips of one trick.
    func testDuplicatesCountTricksNotSurplusClips() {
        let windows = [window(6.9, 11.9), window(7, 11), window(9, 10), window(14, 17.5), window(20, 22)]

        let score = TrickDetectionScore(windows: windows, tricks: [trick, 14.5...17.0])

        XCTAssertEqual(score.outcomes, [.caught, .caught])
        XCTAssertEqual(score.duplicates, 1)
        XCTAssertEqual(score.falsePositives, 1)
    }

    /// Clips that only meet a trick at its ends don't touch it.
    func testClipsEndingWhereATrickStartsAreNotDuplicates() {
        let score = TrickDetectionScore(windows: [window(4, 7.3), window(7.3, 10.5), window(10.5, 12)], tricks: [trick])

        XCTAssertEqual(score.duplicates, 0)
        XCTAssertEqual(score.falsePositives, 2)
    }

    func testACaughtTrickWhosePersonIsInTheCropIsCaught() {
        let score = TrickDetectionScore(
            clips: [clip(6.9, 11.9, crop: leftHalf)], tricks: [positioned(at: 0.3, 0.6)])

        XCTAssertEqual(score.outcomes, [.caught])
    }

    func testACaughtTrickWhosePersonIsOutsideTheCropIsTheWrongPerson() {
        let score = TrickDetectionScore(
            clips: [clip(6.9, 11.9, crop: leftHalf)], tricks: [positioned(at: 0.8, 0.6)])

        XCTAssertEqual(score.outcomes, [.wrongPerson])
        XCTAssertEqual(score.caught, 0)
        XCTAssertEqual(score.wrongPerson, 1)
        XCTAssertEqual(score.summary, "W+0fp+0dup")
    }

    /// Two people's tracks both cut the trick; the clip framing the person who did it is one the
    /// user can keep.
    func testOneClipFramingThePersonIsEnoughWhenSeveralCatchTheTrick() {
        let clips = [clip(6.9, 11.9, crop: leftHalf), clip(7, 11, crop: rightHalf)]

        let score = TrickDetectionScore(clips: clips, tricks: [positioned(at: 0.8, 0.6)])

        XCTAssertEqual(score.outcomes, [.caught])
        XCTAssertEqual(score.duplicates, 1)
    }

    /// Only clips that catch the trick are checked: a partial clip framing the person doesn't
    /// rescue a caught clip framing someone else.
    func testAPartialClipFramingThePersonDoesNotCount() {
        let clips = [clip(6.9, 11.9, crop: leftHalf), clip(9, 12, crop: rightHalf)]

        let score = TrickDetectionScore(clips: clips, tricks: [positioned(at: 0.8, 0.6)])

        XCTAssertEqual(score.outcomes, [.wrongPerson])
    }

    func testAPartlyCaughtTrickStaysPartialWhoeverItFrames() {
        let score = TrickDetectionScore(
            clips: [clip(8.9, 13.6, crop: leftHalf)], tricks: [positioned(at: 0.8, 0.6)])

        XCTAssertEqual(score.outcomes, [.partial])
    }

    func testATrickWithoutAPositionIsCaughtWhateverTheCrop() {
        let score = TrickDetectionScore(
            clips: [clip(6.9, 11.9, crop: leftHalf)], tricks: [LabelledTrick(window: trick, person: "teal shirt")])

        XCTAssertEqual(score.outcomes, [.caught])
    }

    /// A crop that spans the person's x but not their y frames someone above or below them.
    func testAPositionAboveOrBelowTheCropIsTheWrongPerson() {
        let topHalf = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 0.5)
        let bottomHalf = NormalizedRect(minX: 0, maxX: 1, minY: 0.5, maxY: 1)

        let below = TrickDetectionScore(clips: [clip(6.9, 11.9, crop: topHalf)], tricks: [positioned(at: 0.3, 0.8)])
        let above = TrickDetectionScore(clips: [clip(6.9, 11.9, crop: bottomHalf)], tricks: [positioned(at: 0.3, 0.2)])

        XCTAssertEqual(below.outcomes, [.wrongPerson])
        XCTAssertEqual(above.outcomes, [.wrongPerson])
    }

    /// The crop's edges are inside it: a person labelled on the edge of the crop is framed.
    func testAPositionOnTheCropsEdgeIsFramed() {
        let score = TrickDetectionScore(
            clips: [clip(6.9, 11.9, crop: leftHalf)], tricks: [positioned(at: 0.5, 1)])

        XCTAssertEqual(score.outcomes, [.caught])
    }

    func testTallySumsScores() {
        var tally = TrickDetectionTally()
        tally.add(TrickDetectionScore(windows: [window(6.9, 11.9)], tricks: [trick]))
        tally.add(TrickDetectionScore(windows: [window(1, 2)], tricks: [trick]))
        tally.add(TrickDetectionScore(
            clips: [clip(6.9, 11.9, crop: leftHalf), clip(8, 9, crop: leftHalf)], tricks: [positioned(at: 0.8, 0.6)]))

        XCTAssertEqual(tally.caught, 1)
        XCTAssertEqual(tally.wrongPerson, 1)
        XCTAssertEqual(tally.missed, 1)
        XCTAssertEqual(tally.falsePositives, 1)
        XCTAssertEqual(tally.duplicates, 1)
        XCTAssertEqual(tally.clipSeconds, 12, accuracy: 1e-9)
        XCTAssertEqual(
            tally.summary,
            "caught 1  wrong person 1  partial 0  missed 1  false positives 1  duplicates 1  clip seconds 12")
    }

    private func window(_ start: TimeInterval, _ end: TimeInterval) -> TrickWindow {
        TrickWindow(startTime: start, endTime: end)
    }

    private func clip(_ start: TimeInterval, _ end: TimeInterval, crop: NormalizedRect) -> ProcessedClip {
        ProcessedClip(window: window(start, end), cropRect: crop)
    }

    private func positioned(at x: Float, _ y: Float) -> LabelledTrick {
        LabelledTrick(window: trick, person: "teal shirt", position: LabelledTrick.Position(x: x, y: y))
    }
}
