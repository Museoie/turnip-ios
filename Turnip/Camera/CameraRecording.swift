import Foundation

/// A finished take, handed from the camera screen to whoever saves it: the temp file, plus the
/// clips detected live while it was being recorded (with the frames they were scored from)
/// when live inference covered the whole take. `detectedClips` is nil when it did not — the
/// model was still loading, the queue shed samples, the device throttled — and the take goes
/// through Processing like a picked video.
struct CameraRecording {
    let fileURL: URL
    let detectedClips: DetectedClips?
}
