import XCTest
@testable import Turnip

/// The Clip List's VoiceOver wording is its own contract: nothing crashes when a label drops
/// the clip's position or states the wrong trash decision, the screen just lies to a listener.
/// Each case pins the full string so a dropped clause fails rather than degrades.
final class ClipListAccessibilityTests: XCTestCase {
    func testCardLabelCountsOffTheClipsPosition() {
        XCTAssertEqual(
            ClipListAccessibility.cardLabel(
                clipNumber: 2, clipCount: 3, spokenDuration: "2.4 seconds",
                isTrashed: false, hasThumbnail: true),
            "Clip 2 of 3, 2.4 seconds, kept")
    }

    /// The original is the source video already in Photos, not a detected clip, so it has no
    /// position in the count.
    func testCardLabelNamesTheOriginalInsteadOfCountingIt() {
        XCTAssertEqual(
            ClipListAccessibility.cardLabel(
                clipNumber: nil, clipCount: 3, spokenDuration: "1 minute, 3 seconds",
                isTrashed: false, hasThumbnail: true),
            "Original video, 1 minute, 3 seconds, kept")
    }

    /// The two trash decisions differ in kind: the original's is a reversible instruction to
    /// Save Clips, a derived clip's removes the card. The wording has to say which.
    func testCardLabelDistinguishesTheTwoTrashDecisions() {
        XCTAssertEqual(
            ClipListAccessibility.cardLabel(
                clipNumber: nil, clipCount: 3, spokenDuration: "1 minute, 3 seconds",
                isTrashed: true, hasThumbnail: true),
            "Original video, 1 minute, 3 seconds, will be deleted")
        XCTAssertEqual(
            ClipListAccessibility.cardLabel(
                clipNumber: 1, clipCount: 3, spokenDuration: "2.4 seconds",
                isTrashed: true, hasThumbnail: true),
            "Clip 1 of 3, 2.4 seconds, discarded")
    }

    /// The UI-test harness waits on this clause to prove the thumbnail fallback engaged, and a
    /// listener otherwise has no way to know the tile is showing a grey square.
    func testCardLabelReportsAMissingThumbnail() {
        XCTAssertEqual(
            ClipListAccessibility.cardLabel(
                clipNumber: 1, clipCount: 1, spokenDuration: "2.4 seconds",
                isTrashed: false, hasThumbnail: false),
            "Clip 1 of 1, 2.4 seconds, kept, thumbnail placeholder")
    }

    /// A run that found clips announces nothing of its own, so this label is where its result
    /// reaches a listener — including the zero case, which must not read as an empty screen.
    func testGridLabelCountsTheDetectedClips() {
        XCTAssertEqual(ClipListAccessibility.gridLabel(clipCount: 3), "3 clips")
        XCTAssertEqual(ClipListAccessibility.gridLabel(clipCount: 1), "1 clip")
        XCTAssertEqual(ClipListAccessibility.gridLabel(clipCount: 0), "No clips")
    }

    func testTrashActionNameSaysWhatTheTapWillDo() {
        XCTAssertEqual(
            ClipListAccessibility.trashActionName(isTrashed: false, isOriginal: false),
            "Discard clip")
        XCTAssertEqual(
            ClipListAccessibility.trashActionName(isTrashed: false, isOriginal: true),
            "Delete original after saving")
        XCTAssertEqual(
            ClipListAccessibility.trashActionName(isTrashed: true, isOriginal: true), "Restore")
        XCTAssertEqual(
            ClipListAccessibility.trashActionName(isTrashed: true, isOriginal: false), "Restore")
    }

    func testDoneValueCountsWhatTheTapCommitsTo() {
        XCTAssertEqual(
            ClipListAccessibility.saveClipsValue(clipCount: 3, deletesOriginal: false),
            "Saves 3 clips to Photos")
        XCTAssertEqual(
            ClipListAccessibility.saveClipsValue(clipCount: 1, deletesOriginal: false),
            "Saves 1 clip to Photos")
    }

    /// Deleting the source video is the one irreversible thing Save Clips does, so it is never left
    /// to the tile's dimmed thumbnail to convey.
    func testDoneValueNamesTheOriginalDeletion() {
        XCTAssertEqual(
            ClipListAccessibility.saveClipsValue(clipCount: 2, deletesOriginal: true),
            "Saves 2 clips to Photos, and deletes the original video")
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
