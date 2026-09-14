import Foundation

/// The one "2.4s"-style renderer for clip-window durations, shared by the triage card,
/// the clip editor (its duration label and the trim timeline's timestamps), and the
/// export confirmation row — one implementation so the three can't drift apart again.
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
}
