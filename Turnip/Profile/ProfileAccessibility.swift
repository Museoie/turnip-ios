import Foundation

/// What the Profile says out loud, and what its cards and rows are called
/// (`docs/ACCESSIBILITY.md` § "Profile"). A progress bar's fill and a grid's tiles are otherwise
/// visual only; their words live here, as plain functions, so the wording is assertable.
enum ProfileAccessibility {
    static func clipCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 clip") : String(localized: "\(count) clips")
    }

    /// The removal confirmation's question (`libraryClipRemovalDialog`): "Delete 3 clips?".
    static func removalTitle(count: Int) -> String {
        count == 1 ? String(localized: "Delete this clip?") : String(localized: "Delete \(count) clips?")
    }

    static func needsANameLabel(count: Int) -> String {
        String(localized: "Needs a name, \(clipCount(count))")
    }

    static func galleryRowLabel(trick: Trick, count: Int) -> String {
        "\(trick.title), \(clipCount(count))"
    }

    static func levelCardLabel(_ progress: TrickProgress) -> String {
        String(localized: "\(progress.trick.title), level \(progress.level)")
    }

    /// The figures the level card's bar draws: "2 of 3 sessions to level 3".
    static func levelCardValue(_ progress: TrickProgress) -> String {
        guard let next = progress.nextLevel else { return String(localized: "Top level") }
        return String(localized: "\(progress.sessions) of \(next.sessions) sessions to level \(next.level)")
    }

    static func repsCardLabel(_ progress: TrickProgress, milestone: Int) -> String {
        String(localized: "\(progress.trick.title), \(milestone) reps")
    }

    /// The figures the reps card's bar draws: "14 of 50 reps".
    static func repsCardValue(_ progress: TrickProgress) -> String {
        guard let next = progress.nextRepMilestone else { return String(localized: "Top milestone") }
        return String(localized: "\(progress.reps) of \(next) reps")
    }

    /// An achievements page tile's reps line: the highest milestone shown, "50 reps".
    static func repsHeadline(_ progress: TrickProgress) -> String {
        progress.repMilestone.map { String(localized: "\($0) reps") } ?? String(localized: "No rep milestone yet")
    }

    /// An achievements page tile's days: "First 3 Oct 2026 · Last 12 Nov 2026", or "Practiced
    /// 3 Oct 2026" when they're one day; `nil` once every clip of the trick has gone.
    static func practicedDays(_ progress: TrickProgress, calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let first = progress.firstClipAt, let last = progress.lastClipAt else { return nil }
        let firstDay = first.formatted(date: .abbreviated, time: .omitted)
        guard !calendar.isDate(first, inSameDayAs: last) else { return String(localized: "Practiced \(firstDay)") }
        return String(localized: "First \(firstDay) · Last \(last.formatted(date: .abbreviated, time: .omitted))")
    }

    /// An achievements page tile's value, in the order the tile draws it.
    static func tileValue(_ progress: TrickProgress) -> String {
        [levelCardValue(progress), repsHeadline(progress), repsCardValue(progress), practicedDays(progress)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// An earned record on the achievements page: "Gainer, level 2", "Gainer, 50 reps".
    static func earnedTitle(_ record: EarnedAchievement, trickTitle: String) -> String {
        switch record.kind {
        case .level: return String(localized: "\(trickTitle), level \(record.step)")
        case .reps: return String(localized: "\(trickTitle), \(record.step) reps")
        }
    }

    /// How the level ladder climbs: "Levels 1 to 5 take 1, 3, 10, 25, and 50 sessions."
    static var levelLadder: String {
        let steps = AchievementLadder.levelSessions.map(String.init).formatted(.list(type: .and))
        return String(localized: "Levels 1 to \(AchievementLadder.levelSessions.count) take \(steps) sessions.")
    }

    /// Where the rep milestones fall: "Rep milestones come at 10, 50, 100, 250, and 500 reps."
    static var repLadder: String {
        let steps = AchievementLadder.repMilestones.map(String.init).formatted(.list(type: .and))
        return String(localized: "Rep milestones come at \(steps) reps.")
    }

    /// What a session and a rep are, and what counts.
    static let ladderNote = String(localized: """
        A session is a day with a clip of the trick, and a rep is a clip of it. Only clips marked \
        as you count, and what's earned stays earned when clips are deleted.
        """)

    /// A clip's iCloud download, as its status's value: "42 percent".
    static func downloadValue(_ fraction: Double) -> String {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        return String(localized: "\(percent) percent")
    }

    /// Spoken once, as an achievement is earned: "Earned Gainer, level 2". A record is named by
    /// the key it was just earned under, which is the trick's current name.
    static func earnedAnnouncement(_ earned: [EarnedAchievement]) -> String {
        earned.map { record in
            let title = Trick(key: record.trick, name: record.trick).title
            switch record.kind {
            case .level: return String(localized: "Earned \(title), level \(record.step)")
            case .reps: return String(localized: "Earned \(title), \(record.step) reps")
            }
        }
        .joined(separator: ". ")
    }

    /// A gallery tile: its names, its length, its date, and whose clip it is when not the user's.
    static func tileLabel(_ clip: LibraryClip, spokenDuration: String, date: String, isInPhotos: Bool) -> String {
        var parts = [
            clip.names.isEmpty ? String(localized: "Unnamed clip") : clip.names.map(\.name).joined(separator: ", ")
        ]
        parts.append(spokenDuration)
        parts.append(date)
        if !clip.isMe { parts.append(String(localized: "someone else")) }
        if !isInPhotos { parts.append(String(localized: "video not in Photos")) }
        return parts.joined(separator: ", ")
    }
}
