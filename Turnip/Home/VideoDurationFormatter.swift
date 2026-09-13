import Foundation

/// Formats a clip length the way Photos.app labels its video tiles: `m:ss`, with an hours field
/// only when needed (`0:07`, `1:05`, `1:02:03`). Rounds to the nearest whole second.
enum VideoDurationFormatter {
    static func string(from duration: TimeInterval) -> String {
        let totalSeconds = duration.isFinite ? max(0, Int(duration.rounded())) : 0
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Spoken form of a duration for VoiceOver labels: "12 seconds", "1 minute, 5 seconds",
    /// "1 hour, 2 minutes, 3 seconds". The `m:ss` badge format reads badly through a screen
    /// reader ("0:12" is announced "zero twelve"), so tile accessibility labels use this instead.
    /// Same rounding and degenerate-input handling as `string(from:)`.
    static func accessibilityString(from duration: TimeInterval) -> String {
        let totalSeconds = duration.isFinite ? max(0, Int(duration.rounded())) : 0
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        var parts: [String] = []
        if hours > 0 {
            parts.append(spokenUnit(hours, singular: "hour", plural: "hours"))
        }
        if minutes > 0 {
            parts.append(spokenUnit(minutes, singular: "minute", plural: "minutes"))
        }
        if seconds > 0 || parts.isEmpty {
            parts.append(spokenUnit(seconds, singular: "second", plural: "seconds"))
        }
        return parts.joined(separator: ", ")
    }

    /// Names one duration unit with singular/plural agreement. Branched in code rather than via
    /// a `.stringsdict` plural rule: v1 ships English-only, and keeping the branch here makes
    /// the one place that names units obvious. A translator adds the stringsdict — and its
    /// per-language plural rules — when a second language lands.
    private static func spokenUnit(_ value: Int, singular: String, plural: String) -> String {
        if value == 1 {
            return String(localized: "1 \(singular)")
        }
        return String(localized: "\(value) \(plural)")
    }
}
