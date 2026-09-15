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

    /// Spoken form of a duration for VoiceOver labels: "2.4 seconds", "3 seconds",
    /// "1 second". The "2.4s" badge reads badly through a screen reader ("two point
    /// four ess"), so card labels use this instead. Same rounding and
    /// degenerate-input handling as `string(from:)`: negative, NaN, and infinite
    /// floor to "0.0 seconds".
    static func accessibilityString(from duration: TimeInterval) -> String {
        let seconds = duration.isFinite ? max(0, duration) : 0
        let tenths = Int((seconds * 10).rounded())
        let whole = tenths / 10
        let tenth = tenths % 10
        // Non-whole values are never exactly one second, so they always take the
        // plural; the degenerate floor keeps the tenths form ("0.0 seconds") to
        // match what `string(from:)` renders for the same input.
        if tenth == 0, whole > 0 {
            return spokenUnit(whole, singular: "second", plural: "seconds")
        }
        return String(localized: "\(whole).\(tenth) seconds")
    }

    /// Names a whole-second duration with singular/plural agreement. Branched in code
    /// rather than via a `.stringsdict` plural rule: v1 ships English-only, and
    /// keeping the branch here makes the one place that names units obvious. A
    /// translator adds the stringsdict — and its per-language plural rules — when a
    /// second language lands.
    private static func spokenUnit(_ value: Int, singular: String, plural: String) -> String {
        if value == 1 {
            return String(localized: "1 \(singular)")
        }
        return String(localized: "\(value) \(plural)")
    }
}
