import os

/// Where the live pose path reports what it measured. The acceptance gate in docs/LIVE_POSE.md
/// is read from these lines: record on the device, then collect the log.
enum LivePoseLogger {
    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "LivePose")

    /// One line per finished recording. `.notice` so it persists to the log store rather than
    /// living only in the memory ring buffer, and `.public` so the digits survive redaction.
    static func log(_ outcome: LivePoseOutcome) {
        logger.notice("\(outcome.metrics.summaryLine, privacy: .public)")
        if let errorMessage = outcome.errorMessage {
            logger.error("Live pose inference stopped: \(errorMessage, privacy: .public)")
        }
    }

    static func logModelLoadFailure(_ error: Error) {
        let message = (error as? PoseError)?.errorDescription ?? error.localizedDescription
        logger.error("Live pose unavailable: \(message, privacy: .public)")
    }
}
