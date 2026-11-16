import Foundation

/// A finished take, handed from the camera screen to whoever saves it: the temp file, plus the
/// clips detected live while it was being recorded (with the frames they were scored from)
/// when live inference covered the whole take. `detectedClips` is nil when it did not — the
/// model was still loading, the queue shed samples, the device throttled — and the take goes
/// through Processing like a picked video.
struct CameraRecording {
    let fileURL: URL
    let detectedClips: DetectedClips?
    /// What live inference did score when it fell short, so Processing analyzes only the rest.
    /// Nil when `detectedClips` is set, and when nothing was scored live at all.
    var partialPose: PartialPoseFrames?
    /// Every frame live inference scored, whether or not they covered the take: what the pose
    /// archive keeps for the take once it is in Photos (`VideoPoseArchive`), so analyzing it again
    /// later reuses them. Nil when nothing was scored live.
    var livePose: PartialPoseFrames?
}
