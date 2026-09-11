import os

enum PoseResultLogger {
    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "PoseDiagnostic")

    static func log(_ result: PoseFrameResult) {
        let index = result.frameIndex
        let timestamp = String(format: "%.2f", result.timestamp)
        let confidence = String(format: "%.2f", result.averageConfidence)
        let usable = result.usableKeypointCount
        logger.info(
            "frame \(index) t=\(timestamp)s avgConfidence=\(confidence) usableKeypoints=\(usable)/17"
        )
    }
}
