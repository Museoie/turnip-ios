import XCTest
@testable import Turnip

/// The pipeline reports once per processed frame, so the throttle is the whole point of this
/// policy: a regression that speaks every report is silent at compile time and turns the
/// Processing screen into minutes of uninterruptible speech. Each case therefore pins the
/// milestone a report consumes, not just whether it spoke.
final class ProcessingAnnouncementsTests: XCTestCase {
    func testTheFirstReportSpeaksEvenAtTheStartOfTheRun() {
        let spoken = ProcessingAnnouncements.progressAnnouncement(
            for: ProcessingProgress(frame: 1, totalFrames: 1200), lastAnnounced: nil)

        XCTAssertEqual(spoken?.message, "Analyzing frame 1 of 1200")
        XCTAssertEqual(spoken?.milestone, 0)
    }

    func testReportsInsideTheQuarterAlreadySpokenStaySilent() {
        for frame in [2, 100, 299] {
            XCTAssertNil(
                ProcessingAnnouncements.progressAnnouncement(
                    for: ProcessingProgress(frame: frame, totalFrames: 1200), lastAnnounced: 0),
                "frame \(frame) is still in the first quarter and must not speak again")
        }
    }

    func testCrossingIntoANewQuarterSpeaks() {
        let crossings: [(frame: Int, milestone: Int)] = [(300, 1), (600, 2), (900, 3)]
        for crossing in crossings {
            let spoken = ProcessingAnnouncements.progressAnnouncement(
                for: ProcessingProgress(frame: crossing.frame, totalFrames: 1200),
                lastAnnounced: crossing.milestone - 1)

            XCTAssertEqual(spoken?.milestone, crossing.milestone, "frame \(crossing.frame)")
            XCTAssertEqual(
                spoken?.message, "Analyzing frame \(crossing.frame) of 1200",
                "frame \(crossing.frame)")
        }
    }

    /// A run of known length crosses three quarters after its first report, so a full run
    /// speaks four times — the ceiling this policy exists to hold.
    func testAFullRunOfKnownLengthSpeaksFourTimes() {
        var lastAnnounced: Int?
        var spokenCount = 0
        for frame in 1...1200 {
            let progress = ProcessingProgress(frame: frame, totalFrames: 1200)
            guard let spoken = ProcessingAnnouncements.progressAnnouncement(
                for: progress, lastAnnounced: lastAnnounced)
            else { continue }
            lastAnnounced = spoken.milestone
            spokenCount += 1
        }

        XCTAssertEqual(spokenCount, 4)
        XCTAssertEqual(lastAnnounced, ProcessingAnnouncements.milestoneCount - 1)
    }

    /// The last frame lands on a fraction of exactly 1, which is one past the final quarter's
    /// index — unclamped it would be a fifth milestone and a fifth announcement.
    func testTheCompletedFractionClampsIntoTheFinalQuarter() {
        XCTAssertEqual(
            ProcessingAnnouncements.milestone(for: ProcessingProgress(frame: 1200, totalFrames: 1200)),
            ProcessingAnnouncements.milestoneCount - 1)
        XCTAssertNil(
            ProcessingAnnouncements.progressAnnouncement(
                for: ProcessingProgress(frame: 1200, totalFrames: 1200), lastAnnounced: 3))
    }

    /// The denominator is estimated from an average frame rate, so a variable-frame-rate
    /// capture overruns it and `fraction` clamps several reports onto the final quarter.
    func testAnOverrunningCountDoesNotSpeakAgain() {
        XCTAssertNil(
            ProcessingAnnouncements.progressAnnouncement(
                for: ProcessingProgress(frame: 1412, totalFrames: 1200), lastAnnounced: 3))
    }

    func testAReportBehindTheQuarterAlreadySpokenStaysSilent() {
        XCTAssertNil(
            ProcessingAnnouncements.progressAnnouncement(
                for: ProcessingProgress(frame: 300, totalFrames: 1200), lastAnnounced: 3))
    }

    /// A track that reports no frame rate has no quarters to cross, so it announces that the
    /// run started and then leaves the listener alone; a bare frame counter repeated every
    /// frame carries nothing to act on.
    func testAnUnknownLengthSpeaksOnceAndThenStaysSilent() {
        let first = ProcessingAnnouncements.progressAnnouncement(
            for: ProcessingProgress(frame: 42, totalFrames: nil), lastAnnounced: nil)
        XCTAssertEqual(first?.message, "Analyzing frame 42…")
        XCTAssertEqual(first?.milestone, 0)

        XCTAssertNil(
            ProcessingAnnouncements.progressAnnouncement(
                for: ProcessingProgress(frame: 900, totalFrames: nil), lastAnnounced: 0))
        XCTAssertNil(ProcessingAnnouncements.milestone(for: ProcessingProgress(frame: 42, totalFrames: nil)))
    }

    func testTheFailureAnnouncementCarriesTheReasonTheScreenShows() {
        XCTAssertEqual(
            ProcessingAnnouncements.failureAnnouncement(message: "The video couldn't be read."),
            "Analysis failed. The video couldn't be read.")
    }
}
