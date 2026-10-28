import XCTest
@testable import Turnip

/// The Profile's arithmetic (`docs/PROFILE_DESIGN.md` §4.4, §6, §7): which trick a name counts
/// under, how sessions and reps are counted, what is earned and what stays earned, and what the
/// cards say.
final class AchievementsTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-10-27 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_793_102_400)
    private let day: TimeInterval = 86_400

    private func clip(
        _ names: [String], at date: Date, isMe: Bool = true, origin: LabelOrigin = .typed
    ) -> LibraryClip {
        LibraryClip(
            id: UUID(), sourceAssetID: "source", startTime: 0, endTime: 1, exportAssetID: "export",
            names: names.map { ClipName(name: $0, origin: origin) }, isMe: isMe, isAutoDetected: false,
            recordedAt: date, savedAt: date)
    }

    private func counts(_ clips: [LibraryClip], vocabulary: TrickVocabulary = .seed) -> [String: Achievements.Count] {
        Dictionary(uniqueKeysWithValues: Achievements.counts(of: clips, vocabulary: vocabulary, calendar: utc)
            .map { ($0.trick.key, $0) })
    }

    private func keys(_ label: String, vocabulary: TrickVocabulary = .seed) -> [String] {
        TrickNaming.tricks(for: label, vocabulary: vocabulary).map(\.key)
    }

    // MARK: - Names to tricks

    func testAWholeLabelResolvesThroughItsSpellings() {
        XCTAssertEqual(keys("  Corkscrew "), ["cork"])
        XCTAssertEqual(keys("GAINER"), ["gainer"])
    }

    func testParentheticalsAreStrippedBeforeTheLookup() {
        XCTAssertEqual(keys("gainer (combo)"), ["gainer"])
    }

    /// The farm's own example (`TRAINING_DESIGN.md` §2.2): only a whole-label miss is split.
    func testAComboLabelSplitsOnItsSeparators() {
        XCTAssertEqual(keys("hook - scoot - gainer - cartfull (combo)"), ["hook", "scoot", "gainer", "cartfull"])
        XCTAssertEqual(keys("cork+gainer/hook,scoot"), ["cork", "gainer", "hook", "scoot"])
    }

    func testAMappedNameWithASeparatorIsNotSplit() {
        let vocabulary = TrickVocabulary(taxonomyVersion: 2, entries: [
            TrickVocabulary.Entry(canonical: "b-twist", aliases: ["btwist", "b twist"])
        ])
        XCTAssertEqual(keys("B-Twist", vocabulary: vocabulary), ["b-twist"])
        XCTAssertEqual(keys("b twist", vocabulary: vocabulary), ["b-twist"])
    }

    /// A name the vocabulary doesn't know is still the user's trick, under its normalized text.
    func testAnUnmappedNameKeepsItsNormalizedText() {
        XCTAssertEqual(keys("Back   Flip"), ["back flip"])
        XCTAssertEqual(keys("cork + flash kick"), ["cork", "flash kick"])
        XCTAssertEqual(keys("(combo)"), [])
    }

    func testAClipsNamesGiveEachTrickOnce() {
        let names = ["gainer", "Gainer (combo)", "cork - gainer"].map { ClipName(name: $0, origin: .typed) }
        XCTAssertEqual(TrickNaming.tricks(in: names, vocabulary: .seed).map(\.key), ["gainer", "cork"])
    }

    func testATricksTitleCapitalizesItsName() {
        XCTAssertEqual(Trick(key: "back flip", name: "back flip").title, "Back flip")
        XCTAssertEqual(Trick(key: "back flip", name: "back flip").identifier, "back-flip")
    }

    // MARK: - Gallery

    func testTheGalleryGroupsByTrickNewestFirstAndAComboUnderEach() {
        let old = clip(["cork"], at: noon)
        let combo = clip(["cork + gainer"], at: noon.addingTimeInterval(day))
        let other = clip(["gainer"], at: noon.addingTimeInterval(2 * day), isMe: false)

        let mine = TrickGallery.groups(of: [old, combo, other], filter: .mine, vocabulary: .seed)
        XCTAssertEqual(mine.map(\.trick.key), ["cork", "gainer"])
        XCTAssertEqual(mine[0].clips, [combo, old])
        XCTAssertEqual(mine[1].clips, [combo])

        let everyone = TrickGallery.groups(of: [old, combo, other], filter: .everyone, vocabulary: .seed)
        XCTAssertEqual(everyone.map(\.trick.key), ["gainer", "cork"])
        XCTAssertEqual(everyone[0].clips, [other, combo])
    }

    func testAnUnnamedClipIsInNoGalleryRow() {
        XCTAssertEqual(TrickGallery.groups(of: [clip([], at: noon)], filter: .everyone, vocabulary: .seed), [])
    }

    // MARK: - Ladders

    func testTheLevelLadderCountsSessions() {
        XCTAssertEqual([0, 1, 2, 3, 9, 10, 25, 49, 50, 400].map(AchievementLadder.level(forSessions:)),
                       [0, 1, 1, 2, 2, 3, 4, 4, 5, 5])
        XCTAssertEqual(AchievementLadder.sessions(forLevelAfter: 0), 1)
        XCTAssertEqual(AchievementLadder.sessions(forLevelAfter: 2), 10)
        XCTAssertNil(AchievementLadder.sessions(forLevelAfter: 5))
    }

    func testRepMilestones() {
        XCTAssertEqual(AchievementLadder.milestones(forReps: 9), [])
        XCTAssertEqual(AchievementLadder.milestones(forReps: 120), [10, 50, 100])
        XCTAssertEqual(AchievementLadder.milestone(after: 0), 10)
        XCTAssertEqual(AchievementLadder.milestone(after: 100), 250)
        XCTAssertNil(AchievementLadder.milestone(after: 500))
    }

    // MARK: - Counting

    /// Sessions are local calendar days: two clips the same day are one session, and a session
    /// past midnight counts as two.
    func testSessionsAreCalendarDaysAndRepsAreClips() {
        let lateNight = Date(timeIntervalSince1970: 1_793_143_800) // 2026-10-27 23:30 UTC
        let clips = [
            clip(["gainer"], at: noon),
            clip(["gainer"], at: lateNight),
            clip(["gainer"], at: lateNight.addingTimeInterval(3_600))
        ]
        let gainer = counts(clips)["gainer"]
        XCTAssertEqual(gainer?.sessions, 2)
        XCTAssertEqual(gainer?.reps, 3)
        XCTAssertEqual(gainer?.firstClipAt, noon)
        XCTAssertEqual(gainer?.lastClipAt, lateNight.addingTimeInterval(3_600))
    }

    func testAClipOfSomeoneElseCountsTowardNothing() {
        XCTAssertNil(counts([clip(["gainer"], at: noon, isMe: false)])["gainer"])
    }

    /// Two spellings of one trick on a clip are still one rep; a combo is a rep of each trick.
    func testAComboCountsOncePerDistinctTrick() {
        let tallies = counts([clip(["cork", "corkscrew", "gainer"], at: noon)])
        XCTAssertEqual(tallies["cork"]?.reps, 1)
        XCTAssertEqual(tallies["gainer"]?.reps, 1)
    }

    /// Rule 3: where a name came from never changes what it counts.
    func testOriginDoesNotChangeTheCount() {
        let typed = counts([clip(["gainer"], at: noon, origin: .typed)])
        let model = counts([clip(["gainer"], at: noon, origin: .model)])
        XCTAssertEqual(typed["gainer"]?.reps, model["gainer"]?.reps)
        XCTAssertEqual(typed["gainer"]?.sessions, model["gainer"]?.sessions)
    }

    // MARK: - Earning

    func testEachLevelAndMilestoneReachedIsItsOwnRecord() {
        let clips = (0..<10).map { clip(["gainer"], at: noon.addingTimeInterval(Double($0 % 3) * day)) }
        let earned = Achievements.newlyEarned(
            counts: Achievements.counts(of: clips, vocabulary: .seed, calendar: utc), earned: [],
            vocabulary: .seed, at: noon)
        XCTAssertEqual(earned.map { "\($0.kind.rawValue)-\($0.step)" }, ["level-1", "level-2", "reps-10"])
        XCTAssertTrue(earned.allSatisfy { $0.trick == "gainer" && $0.earnedAt == noon })
    }

    func testOnlyWhatIsNotYetRecordedIsEarnedAgain() {
        let already = [EarnedAchievement(trick: "gainer", kind: .level, step: 1, earnedAt: noon)]
        let clips = (0..<3).map { clip(["gainer"], at: noon.addingTimeInterval(Double($0) * day)) }
        let earned = Achievements.newlyEarned(
            counts: Achievements.counts(of: clips, vocabulary: .seed, calendar: utc), earned: already,
            vocabulary: .seed, at: noon)
        XCTAssertEqual(earned.map(\.step), [2])
    }

    /// Rule 6: a level reached stays shown when the count drops, and the next step reads from the
    /// count as it is now.
    func testEarnedStaysEarnedWhenTheCountDrops() throws {
        let earned = [
            EarnedAchievement(trick: "gainer", kind: .level, step: 3, earnedAt: noon),
            EarnedAchievement(trick: "gainer", kind: .reps, step: 50, earnedAt: noon)
        ]
        let progress = Achievements.progress(
            counts: Achievements.counts(of: [clip(["gainer"], at: noon)], vocabulary: .seed, calendar: utc),
            earned: earned, vocabulary: .seed)
        let gainer = try XCTUnwrap(progress.first)
        XCTAssertEqual(gainer.level, 3)
        XCTAssertEqual(gainer.sessions, 1)
        XCTAssertEqual(gainer.nextLevel?.level, 4)
        XCTAssertEqual(gainer.nextLevel?.sessions, 25)
        XCTAssertEqual(gainer.repMilestone, 50)
        XCTAssertEqual(gainer.nextRepMilestone, 100)
    }

    /// A vocabulary update that maps a name the user had been using carries what it earned to the
    /// canonical trick.
    func testWhatAnUnmappedNameEarnedMovesWithAVocabularyUpdate() throws {
        let earned = [EarnedAchievement(trick: "gaynor", kind: .level, step: 2, earnedAt: noon)]
        let mapped = TrickVocabulary(taxonomyVersion: 2, entries: [
            TrickVocabulary.Entry(canonical: "gainer", aliases: ["gainer", "gaynor"])
        ])
        let progress = Achievements.progress(
            counts: Achievements.counts(of: [clip(["gainer"], at: noon)], vocabulary: mapped, calendar: utc),
            earned: earned, vocabulary: mapped)
        XCTAssertEqual(progress.map(\.trick.key), ["gainer"])
        XCTAssertEqual(try XCTUnwrap(progress.first).level, 2)
    }

    func testATrickWithOnlyWhatItEarnedSortsLast() {
        let earned = [EarnedAchievement(trick: "hook", kind: .level, step: 1, earnedAt: noon)]
        let progress = Achievements.progress(
            counts: Achievements.counts(of: [clip(["cork"], at: noon)], vocabulary: .seed, calendar: utc),
            earned: earned, vocabulary: .seed)
        XCTAssertEqual(progress.map(\.trick.key), ["cork", "hook"])
        XCTAssertNil(progress[1].lastClipAt)
        XCTAssertEqual(progress[1].reps, 0)
    }

    // MARK: - Words

    private func progress(sessions: Int, reps: Int, level: Int, milestone: Int?) -> TrickProgress {
        TrickProgress(
            trick: Trick(key: "gainer", name: "gainer"), sessions: sessions, reps: reps, firstClipAt: noon,
            lastClipAt: noon, level: level, repMilestone: milestone)
    }

    func testCardsSayTheirFigures() {
        let gainer = progress(sessions: 7, reps: 14, level: 2, milestone: 10)
        XCTAssertEqual(ProfileAccessibility.levelCardLabel(gainer), "Gainer, level 2")
        XCTAssertEqual(ProfileAccessibility.levelCardValue(gainer), "7 of 10 sessions to level 3")
        XCTAssertEqual(ProfileAccessibility.repsCardLabel(gainer, milestone: 10), "Gainer, 10 reps")
        XCTAssertEqual(ProfileAccessibility.repsCardValue(gainer), "14 of 50 reps")

        let top = progress(sessions: 60, reps: 600, level: 5, milestone: 500)
        XCTAssertEqual(ProfileAccessibility.levelCardValue(top), "Top level")
        XCTAssertEqual(ProfileAccessibility.repsCardValue(top), "Top milestone")
    }

    func testAnEarnedAnnouncementNamesEachStep() {
        let earned = [
            EarnedAchievement(trick: "gainer", kind: .level, step: 2, earnedAt: noon),
            EarnedAchievement(trick: "back flip", kind: .reps, step: 10, earnedAt: noon)
        ]
        XCTAssertEqual(
            ProfileAccessibility.earnedAnnouncement(earned), "Earned Gainer, level 2. Earned Back flip, 10 reps")
    }

    func testRowsAndTilesSayWhatTheyHold() {
        XCTAssertEqual(ProfileAccessibility.needsANameLabel(count: 1), "Needs a name, 1 clip")
        XCTAssertEqual(
            ProfileAccessibility.galleryRowLabel(trick: Trick(key: "cork", name: "cork"), count: 3), "Cork, 3 clips")
        let someoneElse = clip(["cork", "gainer"], at: noon, isMe: false)
        XCTAssertEqual(
            ProfileAccessibility.tileLabel(someoneElse, spokenDuration: "1 second", date: "Oct 27", isInPhotos: false),
            "cork, gainer, 1 second, Oct 27, someone else, video not in Photos")
    }
}
