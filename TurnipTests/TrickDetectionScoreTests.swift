import XCTest
@testable import Turnip

final class TrickDetectionScoreTests: XCTestCase {
    private let trick: ClosedRange<TimeInterval> = 7.3...10.5

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

        XCTAssertEqual(score.summary, "PPMCC+1fp")
    }

    func testTallySumsScores() {
        var tally = TrickDetectionTally()
        tally.add(TrickDetectionScore(windows: [window(6.9, 11.9)], tricks: [trick]))
        tally.add(TrickDetectionScore(windows: [window(1, 2)], tricks: [trick]))

        XCTAssertEqual(tally.caught, 1)
        XCTAssertEqual(tally.missed, 1)
        XCTAssertEqual(tally.falsePositives, 1)
        XCTAssertEqual(tally.clipSeconds, 6, accuracy: 1e-9)
    }

    private func window(_ start: TimeInterval, _ end: TimeInterval) -> TrickWindow {
        TrickWindow(startTime: start, endTime: end)
    }
}
