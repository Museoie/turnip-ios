import Foundation

/// Rotates frame-normalized keypoints between the two orientations the live path straddles.
///
/// The video data output hands over buffers in the sensor's own orientation (rotating them
/// physically is expensive and reconfigures the capture pipeline), while the movie output writes
/// its orientation as a track matrix and the file-based sampler renders through that matrix.
/// `relativeDegrees` gives the rotation between the two connections, which
/// `PoseInputPreparer.prepare` applies to the frame before letterboxing, so scored keypoints
/// already arrive in the file's display orientation. `rotated` takes them from there to
/// capture-device space for the camera preview's overlay.
///
/// Angles follow `AVCaptureConnection.videoRotationAngle`: degrees clockwise, a multiple of 90.
/// An angle that is not a multiple of 90 leaves the keypoints untouched — no capture connection
/// reports one, and guessing a mapping would be worse than an unrotated skeleton.
enum LivePoseKeypointRotation {
    /// The rotation that takes the producer connection's frame to the consumer connection's.
    static func relativeDegrees(producer: Int, consumer: Int) -> Int {
        ((consumer - producer) % 360 + 360) % 360
    }

    static func rotated(_ keypoints: [PoseKeypoint], clockwiseDegrees degrees: Int) -> [PoseKeypoint] {
        let turn = (degrees % 360 + 360) % 360
        guard turn != 0 else { return keypoints }
        return keypoints.map { keypoint in
            let (x, y) = rotatedPoint(x: keypoint.x, y: keypoint.y, clockwiseDegrees: turn)
            return PoseKeypoint(name: keypoint.name, y: y, x: x, confidence: keypoint.confidence)
        }
    }

    /// A unit-square point after a clockwise quarter-turn rotation of the image it sits in.
    static func rotatedPoint(x: Float, y: Float, clockwiseDegrees degrees: Int) -> (x: Float, y: Float) {
        switch (degrees % 360 + 360) % 360 {
        case 90:
            return (x: 1 - y, y: x)
        case 180:
            return (x: 1 - x, y: 1 - y)
        case 270:
            return (x: y, y: 1 - x)
        default:
            return (x: x, y: y)
        }
    }
}
