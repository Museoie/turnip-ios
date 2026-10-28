import Foundation

/// What the Profile says out loud, and what its cards and rows are called
/// (`docs/ACCESSIBILITY.md` § "Profile"). A progress bar's fill and a grid's tiles are otherwise
/// visual only; their words live here, as plain functions, so the wording is assertable.
enum ProfileAccessibility {
    static func clipCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 clip") : String(localized: "\(count) clips")
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
