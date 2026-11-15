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

        let someoneElse = TrickGallery.groups(of: [old, combo, other], filter: .someoneElse, vocabulary: .seed)
        XCTAssertEqual(someoneElse.map(\.trick.key), ["gainer"])
        XCTAssertEqual(someoneElse[0].clips, [other])
    }

    /// The two filters split the library: a clip of the user's never shows under someone else.
    func testEachClipIsUnderExactlyOneFilter() {
        let mine = clip(["cork"], at: noon)
        let theirs = clip(["cork"], at: noon.addingTimeInterval(day), isMe: false)

        XCTAssertEqual(
            TrickGallery.groups(of: [mine, theirs], filter: .mine, vocabulary: .seed).flatMap(\.clips), [mine])
        XCTAssertEqual(
            TrickGallery.groups(of: [mine, theirs], filter: .someoneElse, vocabulary: .seed).flatMap(\.clips),
            [theirs])
    }

    func testAnUnnamedClipIsInNoGalleryRow() {
        for filter in TrickGallery.Filter.allCases {
            XCTAssertEqual(TrickGallery.groups(of: [clip([], at: noon)], filter: filter, vocabulary: .seed), [])
            XCTAssertEqual(
                TrickGallery.groups(of: [clip([], at: noon, isMe: false)], filter: filter, vocabulary: .seed), [])
        }
    }

    // MARK: - Achievements page

    /// A combo is one clip but a rep of each trick; someone else's clips and unnamed ones count
    /// toward no total.
    func testTheSummaryCountsTheUsersNamedClipsOnce() {
        let lateNight = Date(timeIntervalSince1970: 1_793_143_800) // 2026-10-27 23:30 UTC
        let clips = [
            clip(["cork + gainer"], at: noon),
            clip(["gainer"], at: lateNight.addingTimeInterval(3_600)),
            clip([], at: noon.addingTimeInterval(5 * day)),
            clip(["hook"], at: noon.addingTimeInterval(9 * day), isMe: false)
        ]
        let progress = Achievements.progress(
            counts: Achievements.counts(of: clips, vocabulary: .seed, calendar: utc), earned: [], vocabulary: .seed)
        let summary = Achievements.summary(of: clips, progress: progress, vocabulary: .seed, calendar: utc)

        XCTAssertEqual(summary, Achievements.Summary(tricks: 2, sessions: 2, clips: 2, achievements: 2))
    }

    /// Every level and rep milestone a trick shows counts, earned ones a dropped count no longer
    /// reaches among them.
    func testTheSummaryCountsEveryLevelAndMilestoneShown() {
        let earned = [
            EarnedAchievement(trick: "gainer", kind: .level, step: 3, earnedAt: noon),
            EarnedAchievement(trick: "gainer", kind: .reps, step: 50, earnedAt: noon)
        ]
        let clips = [clip(["gainer"], at: noon)]
        let progress = Achievements.progress(
            counts: Achievements.counts(of: clips, vocabulary: .seed, calendar: utc), earned: earned,
            vocabulary: .seed)
        let summary = Achievements.summary(of: clips, progress: progress, vocabulary: .seed, calendar: utc)

        XCTAssertEqual(summary.achievements, 5)
        XCTAssertEqual(summary.sessions, 1)
    }

    func testRecentlyEarnedIsNewestFirstAndCapped() {
        let first = EarnedAchievement(trick: "gainer", kind: .level, step: 1, earnedAt: noon)
        let together = [
            EarnedAchievement(trick: "gainer", kind: .reps, step: 10, earnedAt: noon.addingTimeInterval(day)),
            EarnedAchievement(trick: "cork", kind: .level, step: 2, earnedAt: noon.addingTimeInterval(day)),
            EarnedAchievement(trick: "gainer", kind: .level, step: 2, earnedAt: noon.addingTimeInterval(day))
        ]
        let latest = EarnedAchievement(trick: "hook", kind: .level, step: 1, earnedAt: noon.addingTimeInterval(2 * day))

        XCTAssertEqual(
            Achievements.recentlyEarned([first] + together + [latest], limit: 4),
            [latest, together[1], together[2], together[0]])
        XCTAssertEqual(Achievements.recentlyEarned([first, latest], limit: 10), [latest, first])
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

    func testAnAchievementsTileSaysItsFiguresAndDays() {
        let gainer = TrickProgress(
            trick: Trick(key: "gainer", name: "gainer"), sessions: 7, reps: 14, firstClipAt: noon,
            lastClipAt: noon.addingTimeInterval(3 * day), level: 2, repMilestone: 10)
        let first = noon.formatted(date: .abbreviated, time: .omitted)
        let last = noon.addingTimeInterval(3 * day).formatted(date: .abbreviated, time: .omitted)

        XCTAssertEqual(ProfileAccessibility.repsHeadline(gainer), "10 reps")
        XCTAssertEqual(ProfileAccessibility.practicedDays(gainer, calendar: utc), "First \(first) · Last \(last)")
        XCTAssertEqual(
            ProfileAccessibility.tileValue(gainer),
            "7 of 10 sessions to level 3, 10 reps, 14 of 50 reps, First \(first) · Last \(last)")
    }

    /// One day reads as one, a trick with no milestone yet says so, and one whose clips are all
    /// gone has no days to give.
    func testAnAchievementsTileWithOneDayNoMilestoneOrNoClips() {
        let oneDay = progress(sessions: 1, reps: 3, level: 1, milestone: nil)
        XCTAssertEqual(ProfileAccessibility.repsHeadline(oneDay), "No rep milestone yet")
        XCTAssertEqual(
            ProfileAccessibility.practicedDays(oneDay, calendar: utc),
            "Practiced \(noon.formatted(date: .abbreviated, time: .omitted))")

        let earnedOnly = TrickProgress(
            trick: Trick(key: "hook", name: "hook"), sessions: 0, reps: 0, firstClipAt: nil, lastClipAt: nil,
            level: 1, repMilestone: nil)
        XCTAssertNil(ProfileAccessibility.practicedDays(earnedOnly))
    }

    func testTheLaddersAndEarnedRecordsSayTheirSteps() {
        XCTAssertEqual(
            ProfileAccessibility.earnedTitle(
                EarnedAchievement(trick: "gainer", kind: .reps, step: 50, earnedAt: noon), trickTitle: "Gainer"),
            "Gainer, 50 reps")
        XCTAssertEqual(
            ProfileAccessibility.earnedTitle(
                EarnedAchievement(trick: "gainer", kind: .level, step: 2, earnedAt: noon), trickTitle: "Gainer"),
            "Gainer, level 2")
        XCTAssertEqual(ProfileAccessibility.levelLadder, "Levels 1 to 5 take 1, 3, 10, 25, and 50 sessions.")
        XCTAssertEqual(ProfileAccessibility.repLadder, "Rep milestones come at 10, 50, 100, 250, and 500 reps.")
    }

    func testTheRemovalQuestionCountsTheClips() {
        XCTAssertEqual(ProfileAccessibility.removalTitle(count: 1), "Delete this clip?")
        XCTAssertEqual(ProfileAccessibility.removalTitle(count: 12), "Delete 12 clips?")
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
