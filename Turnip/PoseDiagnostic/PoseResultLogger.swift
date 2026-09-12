import os

enum PoseResultLogger {
    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "PoseDiagnostic")

    /// The per-frame diagnostic line, rendered as a plain `String` so tests can assert on the
    /// exact emitted text. Rendered up front rather than interpolated at the call site: `os.Logger`
    /// redacts interpolated `String` values to `<private>` by default, which would silently drop
    /// the two numbers this line exists to carry.
    static func line(for result: PoseFrameResult) -> String {
        let timestamp = String(format: "%.2f", result.timestamp)
        let confidence = String(format: "%.2f", result.averageConfidence)
        let usable = "\(result.usableKeypointCount)/\(PoseKeypoint.names.count)"
        return "frame \(result.frameIndex) t=\(timestamp)s avgConfidence=\(confidence) usableKeypoints=\(usable)"
    }

    static func log(_ result: PoseFrameResult) {
        // `privacy: .public` keeps the confidence/timestamp digits in the log — without it they
        // arrive as Strings and are redacted to `<private>`. `.notice` rather than `.info` so
        // entries persist to the log store for the record-first-then-collect workflow: `.info`
        // entries live only in the memory ring buffer until collected.
        logger.notice("\(line(for: result), privacy: .public)")
    }
}
