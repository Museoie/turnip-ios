import Foundation

/// What the Clip List says out loud, and what its cards are called.
///
/// Three of this screen's states are otherwise purely visual. A card conveys its clip by
/// position in a grid and its length by a "2.4s" caption; the save puts a silent spinner
/// over a disabled grid and then pops to Home; and the zero-tricks notice fades itself out
/// after a few seconds. Each gets a spoken form here, as plain functions, so the wording is
/// assertable without a screen reader.
enum ClipListAccessibility {
    /// One card's label. `clipNumber` is `nil` for an item that isn't among the clips, whose
    /// label then goes without a position.
    ///
    /// `hasThumbnail` appends the placeholder state: a card whose frame has not decoded shows
    /// a grey square, which is information a listener otherwise has no way to reach.
    static func cardLabel(
        clipNumber: Int?,
        clipCount: Int,
        spokenDuration: String,
        hasThumbnail: Bool
    ) -> String {
        var parts: [String] = []
        if let clipNumber {
            parts.append(String(localized: "Clip \(clipNumber) of \(clipCount)"))
        }
        parts.append(spokenDuration)
        if !hasThumbnail {
            parts.append(String(localized: "thumbnail placeholder"))
        }
        return parts.joined(separator: ", ")
    }

    /// What Save Clips is going to do, as its `accessibilityValue`. The button says only "Save
    /// Clips", so without this the count it commits to is visible only by counting tiles.
    static func saveClipsValue(clipCount: Int) -> String {
        clipCount == 1
            ? String(localized: "Saves 1 clip to Photos")
            : String(localized: "Saves \(clipCount) clips to Photos")
    }

    /// Spoken when Save Clips starts working, because the overlay that replaces the grid is a
    /// progress spinner with no accessible text of its own.
    static func saveStarting(clipCount: Int) -> String {
        clipCount == 1
            ? String(localized: "Saving 1 clip to Photos")
            : String(localized: "Saving \(clipCount) clips to Photos")
    }

    /// Spoken once every clip has landed. Without it the only completion signal is the
    /// spinner leaving, which is exactly what this screen inherited from the retired export
    /// confirmation screen's checklist item.
    static func saveFinished(clipCount: Int) -> String {
        clipCount == 1
            ? String(localized: "Saved 1 clip to Photos")
            : String(localized: "Saved \(clipCount) clips to Photos")
    }

    /// One clip's failure, numbered like its card. A run reports its failures together, so
    /// without the number a listener hearing two reasons cannot tell which clips they belong
    /// to — but a grid of one clip has nothing to disambiguate, and "Clip 1 of 1" there is
    /// pure noise.
    static func saveFailure(clipNumber: Int, clipCount: Int, reason: String) -> String {
        guard clipCount > 1 else { return reason }
        return String(localized: "Clip \(clipNumber) of \(clipCount): \(reason)")
    }

    /// "1 clip" / "N clips", read on entering the grid. A run's result is otherwise reachable
    /// only by swiping every card and counting, and a run that found nothing has to say so
    /// rather than read as an empty screen.
    static func gridLabel(clipCount: Int) -> String {
        switch clipCount {
        case 0: return String(localized: "No clips")
        case 1: return String(localized: "1 clip")
        default: return String(localized: "\(clipCount) clips")
        }
    }

    /// The zero-tricks notice's text, shared by the visible notice and its announcement so
    /// the two cannot drift.
    static var noTricksFound: String { String(localized: "No tricks found") }
}
