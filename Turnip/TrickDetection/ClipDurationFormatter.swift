import Foundation

/// The one "2.4s"-style renderer for clip-window durations, shared by the clip list's tiles
/// (duration and range timeline) and the clip editor (its duration label and the trim
/// timeline's timestamps) — one implementation so the screens can't drift apart.
///
/// Integer math pins exactly one decimal place: string-interpolating the `Double` would
/// lean on `Double.description`'s shortest-round-trip rendering for the trailing `.0`,
/// and the decimal separator must never follow the device locale (a German-locale "2,4s"
/// would read as a list separator next to the clip count).
enum ClipDurationFormatter {
    /// "2.4s"-style label for a duration in seconds. Whole seconds keep the trailing
    /// `.0` — "3.0s", not "3s" — so the same clip reads identically on every screen.
    /// Degenerate inputs (negative, NaN, infinite) render as "0.0s", mirroring
    /// `VideoDurationFormatter`'s floor.
    static func string(from duration: TimeInterval) -> String {
        let seconds = duration.isFinite ? max(0, duration) : 0
        let tenths = Int((seconds * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)s"
    }

    /// Spoken form for VoiceOver labels: "2.4 seconds", "1 second", "3 seconds". The "2.4s"
    /// badge reads as "two point four s" through a screen reader, so accessibility labels take
    /// this instead — the same split `VideoDurationFormatter` makes for the Home grid's tiles.
    /// Built from the same integer tenths, so the two forms can never disagree about a window.
    static func accessibilityString(from duration: TimeInterval) -> String {
        let seconds = duration.isFinite ? max(0, duration) : 0
        let tenths = Int((seconds * 10).rounded())
        guard tenths % 10 != 0 else {
            let whole = tenths / 10
            return whole == 1
                ? String(localized: "1 second")
                : String(localized: "\(whole) seconds")
        }
        return String(localized: "\(tenths / 10).\(tenths % 10) seconds")
    }
}
