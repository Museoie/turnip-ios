import os

enum PoseResultLogger {
    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "PoseDiagnostic")

    /// The per-frame diagnostic line, rendered without `Logger` so tests can assert on the
    /// exact emitted text. This indirection is load-bearing: `os.Logger` redacts `String`
    /// interpolations to `<private>` by default, so the confidence and timestamp would be
    /// silently dropped if they were interpolated as strings at the call site.
    static func line(for result: PoseFrameResult) -> String {
        "frame \(result.frameIndex) t=\(String(format: "%.2f", result.timestamp))s avgConfidence=\(String(format: "%.2f", result.averageConfidence)) usableKeypoints=\(result.usableKeypointCount)/17"
    }

    static func log(_ result: PoseFrameResult) {
        // `privacy: .public` keeps the confidence/timestamp digits in the log — without it they
        // arrive as Strings and are redacted to `<private>` (issue #35). `.notice` rather than
        // `.info` so entries persist to the log store: the empirical test (issue #2) records
        // clips first and pulls the log with `log collect` afterwards, and `.info` entries live
        // only in the memory ring buffer until collected.
        logger.notice("\(line(for: result), privacy: .public)")
    }
}
