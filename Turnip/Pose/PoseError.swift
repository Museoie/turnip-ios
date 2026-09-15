import Foundation

/// Errors from the pose pipeline: frame decode (pipeline step 1), model load, and inference.
///
/// Named for the failure domain, not the caller: the diagnostic screen was the first consumer,
/// but these errors belong to the pipeline itself, so deleting the screen must never strand them.
enum PoseError: LocalizedError {
    case modelNotFound
    case videoLoadFailed(underlying: Error?)
    case inferenceFailed(String)
    /// The model file loaded but failed the variant check (e.g. a Lightning
    /// 192x192 file where Thunder 256x256 was expected). Typed separately from
    /// `inferenceFailed` so the OTA loader can discriminate a bad *file*
    /// (which should evict the staged record) from a transient load failure
    /// (which must not drop a good staged model).
    case wrongModelVariant(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "MoveNet Thunder model not found. See Turnip/Models/README.md for download instructions."
        case .videoLoadFailed(let underlying):
            if let underlying {
                return "Failed to load the selected video: \(underlying.localizedDescription)"
            }
            return "Failed to load the selected video."
        case .inferenceFailed(let message), .wrongModelVariant(let message):
            return "Pose inference failed: \(message)"
        }
    }
}
