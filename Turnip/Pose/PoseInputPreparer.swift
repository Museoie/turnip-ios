import CoreImage
import CoreVideo
import Foundation

/// Turns a source frame into a `PoseModelInput`: letterbox into the model's square input through
/// Core Image, then repack the rendered 32BGRA target as interleaved RGB.
///
/// Synchronous and callable from any thread, which is what lets the live path run it inside the
/// capture output's delegate callback and the file path run it from the sampler's handler, with a
/// single preprocess implementation between them. The source pixel format is not constrained:
/// `CIImage(cvPixelBuffer:)` accepts the camera's native 420v as readily as the file sampler's
/// 32BGRA, and the 32BGRA contract in `FramePreprocessor.packRGB` is on the rendered target.
///
/// `@unchecked Sendable` because `CIContext` carries no `Sendable` annotation; Apple documents it
/// as immutable and thread-safe, and this type holds nothing else that is mutable.
struct PoseInputPreparer: @unchecked Sendable {
    let preprocessor: FramePreprocessor
    private let ciContext: CIContext

    init(preprocessor: FramePreprocessor, ciContext: CIContext = CIContext()) {
        self.preprocessor = preprocessor
        self.ciContext = ciContext
    }

    /// `rotationDegrees` uprights the source before letterboxing it — clockwise, in
    /// `AVCaptureConnection.videoRotationAngle` terms. The file path's frames are already upright
    /// (`VideoFrameSampler` renders through the track's `preferredTransform` first) and uses the
    /// default of 0; the live path's frames arrive in the sensor's own orientation and pass the
    /// rotation from the data connection to the movie connection, so MoveNet always scores an
    /// upright frame instead of a sideways one — it is trained on upright subjects and degrades
    /// noticeably otherwise. Rotating before the letterbox rather than after means only kept frames
    /// pay for it, and it makes `mapping.sourceExtent` already the movie connection's orientation, so
    /// the returned keypoints need no separate rotation once they are frame-normalized.
    func prepare(_ pixelBuffer: CVPixelBuffer, rotationDegrees: Int = 0) throws -> PoseModelInput {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let (uprightTransform, uprightExtent) = FramePreprocessor.uprightTransform(
            forExtent: sourceImage.extent, clockwiseDegrees: rotationDegrees)
        let (letterboxTransform, mapping) = try preprocessor.letterboxGeometry(forSourceExtent: uprightExtent)
        let outputBuffer = try preprocessor.makeTargetBuffer()
        ciContext.render(
            sourceImage.transformed(by: uprightTransform.concatenating(letterboxTransform)), to: outputBuffer)
        return PoseModelInput(tensor: try preprocessor.packRGB(from: outputBuffer), mapping: mapping)
    }
}
