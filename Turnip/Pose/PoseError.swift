import Foundation

/// Errors from the pose pipeline: frame decode (pipeline step 1), model load, and inference.
///
/// Named for the failure domain, not the caller: these errors belong to the pipeline itself, so
/// no one screen that surfaces them owns them.
enum PoseError: LocalizedError {
    case modelNotFound
    case videoLoadFailed(underlying: Error?)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "MoveNet Thunder model not found. See Turnip/Models/README.md for download instructions."
        case .videoLoadFailed(let underlying):
            if let underlying {
                return "Failed to load the selected video: \(underlying.localizedDescription)"
            }
            return "Failed to load the selected video."
        case .inferenceFailed(let message):
            return "Pose inference failed: \(message)"
        }
    }
}
