import XCTest
@testable import Turnip

/// The Clip List's VoiceOver wording is its own contract: nothing crashes when a label drops
/// the clip's position or miscounts a save, the screen just lies to a listener.
/// Each case pins the full string so a dropped clause fails rather than degrades.
final class ClipListAccessibilityTests: XCTestCase {
    func testCardLabelCountsOffTheClipsPosition() {
        XCTAssertEqual(
            ClipListAccessibility.cardLabel(
                clipNumber: 2, clipCount: 3, spokenDuration: "2.4 seconds", hasThumbnail: true),
            "Clip 2 of 3, 2.4 seconds")
    }

    /// The UI-test harness waits on this clause to prove the thumbnail fallback engaged, and a
    /// listener otherwise has no way to know the tile is showing a grey square.
    func testCardLabelReportsAMissingThumbnail() {
        XCTAssertEqual(
            ClipListAccessibility.cardLabel(
                clipNumber: 1, clipCount: 1, spokenDuration: "2.4 seconds", hasThumbnail: false),
            "Clip 1 of 1, 2.4 seconds, thumbnail placeholder")
    }

    /// A run that found clips announces nothing of its own, so this label is where its result
    /// reaches a listener — including the zero case, which must not read as an empty screen.
    func testGridLabelCountsTheDetectedClips() {
        XCTAssertEqual(ClipListAccessibility.gridLabel(clipCount: 3), "3 clips")
        XCTAssertEqual(ClipListAccessibility.gridLabel(clipCount: 1), "1 clip")
        XCTAssertEqual(ClipListAccessibility.gridLabel(clipCount: 0), "No clips")
    }

    func testDoneValueCountsWhatTheTapCommitsTo() {
        XCTAssertEqual(
            ClipListAccessibility.saveClipsValue(clipCount: 3),
            "Saves 3 clips to Photos")
        XCTAssertEqual(
            ClipListAccessibility.saveClipsValue(clipCount: 1),
            "Saves 1 clip to Photos")
    }

    func testSaveAnnouncementsAgreeInNumber() {
        XCTAssertEqual(ClipListAccessibility.saveStarting(clipCount: 1), "Saving 1 clip to Photos")
        XCTAssertEqual(ClipListAccessibility.saveStarting(clipCount: 4), "Saving 4 clips to Photos")
        XCTAssertEqual(ClipListAccessibility.saveFinished(clipCount: 1), "Saved 1 clip to Photos")
        XCTAssertEqual(ClipListAccessibility.saveFinished(clipCount: 4), "Saved 4 clips to Photos")
    }

    /// A run reports its failures together, so an unnumbered reason leaves a listener unable
    /// to tell which clip it belongs to.
    func testSaveFailureNumbersTheClipItBelongsTo() {
        XCTAssertEqual(
            ClipListAccessibility.saveFailure(clipNumber: 2, clipCount: 3, reason: "Export failed"),
            "Clip 2 of 3: Export failed")
    }

    /// A one-clip run has nothing to disambiguate, so the number would only add words to read.
    func testSaveFailureDropsTheNumberForASingleClipRun() {
        XCTAssertEqual(
            ClipListAccessibility.saveFailure(clipNumber: 1, clipCount: 1, reason: "Export failed"),
            "Export failed")
    }
}
