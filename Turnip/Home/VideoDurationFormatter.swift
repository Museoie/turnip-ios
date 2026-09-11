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
}
