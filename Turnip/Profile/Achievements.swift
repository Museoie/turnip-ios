import Foundation

enum AchievementKind: String, Codable, Hashable, Sendable {
    /// Counts sessions: distinct days with the trick.
    case level
    /// Counts clips of the trick.
    case reps
}

/// A level or rep milestone once reached (`docs/PROFILE_DESIGN.md` §6.4). Never deleted: a count
/// that later drops leaves it earned.
struct EarnedAchievement: Codable, Hashable, Sendable {
    /// The trick's key when it was earned. Read back through the vocabulary, so a later merge or
    /// rename carries it to the trick it now resolves to.
    let trick: String
    let kind: AchievementKind
    /// The level for `.level`, the rep count for `.reps`.
    let step: Int
    let earnedAt: Date
}

/// The two ladders every trick has (`docs/PROFILE_DESIGN.md` §6.1), bundled with the app.
enum AchievementLadder {
    /// Sessions needed for levels 1 through 5.
    static let levelSessions = [1, 3, 10, 25, 50]
    static let repMilestones = [10, 50, 100, 250, 500]

    /// The level `sessions` reaches; 0 below the first.
    static func level(forSessions sessions: Int) -> Int {
        levelSessions.filter { sessions >= $0 }.count
    }

    /// Every rep milestone `reps` reaches.
    static func milestones(forReps reps: Int) -> [Int] {
        repMilestones.filter { reps >= $0 }
    }

    /// The sessions the level after `level` needs; `nil` past the top.
    static func sessions(forLevelAfter level: Int) -> Int? {
        levelSessions.indices.contains(level) ? levelSessions[level] : nil
    }

    static func milestone(after reps: Int) -> Int? {
        repMilestones.first { $0 > reps }
    }
}

/// One trick's standing: what the library counts now, and the highest it has ever earned.
struct TrickProgress: Identifiable, Hashable {
    let trick: Trick
    let sessions: Int
    let reps: Int
    /// The date of the trick's first clip; `nil` once every clip of it has left the library.
    let firstClipAt: Date?
    let lastClipAt: Date?
    /// The level shown: the highest earned, which a later drop in sessions never lowers.
    let level: Int
    /// The highest rep milestone earned; `nil` before the first.
    let repMilestone: Int?

    var id: String { trick.key }

    /// The next level and the sessions it needs, past the level shown; `nil` at the top.
    var nextLevel: (level: Int, sessions: Int)? {
        AchievementLadder.sessions(forLevelAfter: level).map { (level + 1, $0) }
    }

    /// The next rep milestone past the highest earned; `nil` at the top.
    var nextRepMilestone: Int? {
        AchievementLadder.milestone(after: repMilestone ?? 0)
    }
}

/// What the Profile's achievements are computed from (`docs/PROFILE_DESIGN.md` §6): a function of
/// each clip's tricks, whether it shows the user, and its date — nothing else. Where a name came
/// from, the blind sample and contribution never enter it.
enum Achievements {
    struct Count: Hashable {
        let trick: Trick
        let sessions: Int
        let reps: Int
        let firstClipAt: Date
        let lastClipAt: Date
    }

    /// The user's own clips counted per trick: a rep per clip, a session per local calendar day, a
    /// combo once under each of its tricks.
    static func counts(of clips: [LibraryClip], vocabulary: TrickVocabulary, calendar: Calendar) -> [Count] {
        struct Tally {
            var trick: Trick
            var days = Set<DateComponents>()
            var reps = 0
            var first = Date.distantFuture
            var last = Date.distantPast
        }
        var tallies: [String: Tally] = [:]
        for clip in clips where clip.isMe {
            let day = calendar.dateComponents([.era, .year, .month, .day], from: clip.recordedAt)
            for trick in TrickNaming.tricks(in: clip.names, vocabulary: vocabulary) {
                var tally = tallies[trick.key] ?? Tally(trick: trick)
                tally.days.insert(day)
                tally.reps += 1
                tally.first = min(tally.first, clip.recordedAt)
                tally.last = max(tally.last, clip.recordedAt)
                tallies[trick.key] = tally
            }
        }
        return tallies.values.map {
            Count(trick: $0.trick, sessions: $0.days.count, reps: $0.reps, firstClipAt: $0.first, lastClipAt: $0.last)
        }
    }

    /// The earned records `counts` calls for that `earned` doesn't hold: every level and milestone
    /// above the highest already earned for the trick, each its own record.
    static func newlyEarned(
        counts: [Count], earned: [EarnedAchievement], vocabulary: TrickVocabulary, at date: Date
    ) -> [EarnedAchievement] {
        let highest = highestEarned(earned, vocabulary: vocabulary)
        return counts.sorted { $0.trick.key < $1.trick.key }.flatMap { count -> [EarnedAchievement] in
            let level = AchievementLadder.level(forSessions: count.sessions)
            let earnedLevel = highest[count.trick.key]?.level ?? 0
            let levels = level > earnedLevel ? Array(earnedLevel + 1...level) : []
            let earnedReps = highest[count.trick.key]?.reps ?? 0
            let milestones = AchievementLadder.milestones(forReps: count.reps).filter { $0 > earnedReps }
            return levels.map { EarnedAchievement(trick: count.trick.key, kind: .level, step: $0, earnedAt: date) }
                + milestones.map { EarnedAchievement(trick: count.trick.key, kind: .reps, step: $0, earnedAt: date) }
        }
    }

    /// Every trick with a clip of the user's or an achievement earned, the one practiced most
    /// recently first; a trick whose clips are all gone keeps what it earned and sorts last.
    static func progress(
        counts: [Count], earned: [EarnedAchievement], vocabulary: TrickVocabulary
    ) -> [TrickProgress] {
        let highest = highestEarned(earned, vocabulary: vocabulary)
        let byTrick = Dictionary(uniqueKeysWithValues: counts.map { ($0.trick.key, $0) })
        var tricks = Dictionary(uniqueKeysWithValues: counts.map { ($0.trick.key, $0.trick) })
        for record in earned {
            for trick in TrickNaming.tricks(for: record.trick, vocabulary: vocabulary) where tricks[trick.key] == nil {
                tricks[trick.key] = trick
            }
        }
        return tricks.values.map { trick in
            let count = byTrick[trick.key]
            let sessions = count?.sessions ?? 0
            let reps = count?.reps ?? 0
            let earnedLevel = highest[trick.key]?.level ?? 0
            let earnedReps = highest[trick.key]?.reps ?? 0
            let milestone = max(AchievementLadder.milestones(forReps: reps).last ?? 0, earnedReps)
            return TrickProgress(
                trick: trick, sessions: sessions, reps: reps,
                firstClipAt: count?.firstClipAt, lastClipAt: count?.lastClipAt,
                level: max(AchievementLadder.level(forSessions: sessions), earnedLevel),
                repMilestone: milestone > 0 ? milestone : nil)
        }
        .sorted { lhs, rhs in
            let lhsLast = lhs.lastClipAt ?? .distantPast
            let rhsLast = rhs.lastClipAt ?? .distantPast
            return lhsLast != rhsLast ? lhsLast > rhsLast : lhs.trick.key < rhs.trick.key
        }
    }

    /// The highest level and rep milestone earned per trick key, each record read through today's
    /// vocabulary.
    private static func highestEarned(
        _ earned: [EarnedAchievement], vocabulary: TrickVocabulary
    ) -> [String: (level: Int, reps: Int)] {
        var highest: [String: (level: Int, reps: Int)] = [:]
        for record in earned {
            for trick in TrickNaming.tricks(for: record.trick, vocabulary: vocabulary) {
                var entry = highest[trick.key] ?? (0, 0)
                switch record.kind {
                case .level: entry.level = max(entry.level, record.step)
                case .reps: entry.reps = max(entry.reps, record.step)
                }
                highest[trick.key] = entry
            }
        }
        return highest
    }
}
