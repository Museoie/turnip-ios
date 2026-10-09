import Foundation

/// One frame reduced to exactly what `MoveNetThunderModel.runInference(on:)` consumes: the packed
/// RGB uint8 tensor plus the letterbox geometry that placed the frame in it, so the keypoints the
/// model returns can be mapped back to frame-normalized coordinates.
///
/// A value type on purpose. The live capture path has to let go of every `CVPixelBuffer` before
/// its delegate callback returns — the capture output recycles them from a small pool — so what
/// crosses from the capture queue to the inference actor is this ~196 KB tensor, never the frame.
struct PoseModelInput: Sendable {
    let tensor: Data
    let mapping: LetterboxMapping
}
