import AVFoundation
import CoreMotion
import Foundation

/// Writes the phone's roll into a recording as it is made (`RollTrack`): an
/// `AVCaptureMetadataInput` on the capture session, connected to the movie output, fed one
/// timed metadata group per gravity sample while the movie output records. Gravity comes
/// from Core Motion's device-motion fusion, which needs no usage-description prompt — only
/// the pedometer and activity APIs do — and nothing leaves the device: the samples go into
/// the user's own movie file and nowhere else (`docs/PRIVACY.md`).
///
/// A reference type with its own lock, like `LivePoseFrameTap`: the motion queue delivers
/// samples off the main actor, and the capture view model starts and stops it from the main
/// actor. On the simulator, which has no motion hardware, `start` is a no-op and the input
/// simply records nothing.
///
/// The same motion updates feed the camera's level indicator (`observeGravity`,
/// `CameraLevelMonitor`), which shows whenever the preview does, so they run while either a
/// take or an observer wants them: one `CMMotionManager` for the app, as Core Motion asks.
final class RollTrackRecorder: @unchecked Sendable {
    /// Where the picture-geometry a take was started with lives for the motion callback.
    private struct Geometry {
        let videoRotationDegrees: Int
        let isFrontCamera: Bool
    }

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.hoiekim.turnip.camera.roll"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let hostClock = CMClockGetHostTimeClock()
    private let lock = NSLock()
    private var input: AVCaptureMetadataInput?
    private var geometry: Geometry?
    /// The end of the last group appended this take, so the next group starts after it: the
    /// input rejects a group that starts before the previous one ends.
    private var lastEnd: CMTime = .invalid
    /// Whether the movie output is recording, for the take being sampled; `nil` between takes.
    private var isRecording: (@Sendable () -> Bool)?
    /// Who else is handed every gravity sample, take or no take.
    private var gravityObserver: (@Sendable (CMAcceleration) -> Void)?
    /// Whether the motion updates are running. Only `updateSampling` changes it, and only the
    /// main actor calls that.
    private var isSampling = false

    /// The capture input this recorder appends to, created once. The caller adds it to the
    /// session and connects it to the movie output inside the session's configuration.
    func makeInput() throws -> AVCaptureMetadataInput {
        let created = AVCaptureMetadataInput(formatDescription: try RollTrack.makeFormatDescription(), clock: hostClock)
        lock.lock()
        input = created
        lock.unlock()
        return created
    }

    /// Starts sampling for a take. `videoRotationDegrees` is the movie connection's rotation
    /// and `isFrontCamera` which camera is recording, both read as the take starts: they
    /// decide how a gravity reading maps into the recorded picture (`RollTrack.tilt`).
    /// `isRecording` is read on every sample, so a sample that arrives after the movie
    /// output has stopped — or before it has started — is dropped rather than appended to
    /// nothing.
    func start(videoRotationDegrees: Int, isFrontCamera: Bool, isRecording: @escaping @Sendable () -> Bool) {
        guard motionManager.isDeviceMotionAvailable else { return }
        lock.lock()
        geometry = Geometry(videoRotationDegrees: videoRotationDegrees, isFrontCamera: isFrontCamera)
        self.isRecording = isRecording
        lastEnd = .invalid
        lock.unlock()
        updateSampling()
    }

    func stop() {
        lock.lock()
        geometry = nil
        isRecording = nil
        lock.unlock()
        updateSampling()
    }

    /// Hands every gravity sample to `observer`, on the motion queue, until it is replaced or
    /// cleared with `nil`: with a take or without one.
    func observeGravity(_ observer: (@Sendable (CMAcceleration) -> Void)?) {
        guard motionManager.isDeviceMotionAvailable else { return }
        lock.lock()
        gravityObserver = observer
        lock.unlock()
        updateSampling()
    }

    /// Runs the motion updates while a take or an observer wants them, and stops them when
    /// neither does.
    private func updateSampling() {
        lock.lock()
        let isWanted = geometry != nil || gravityObserver != nil
        let changes = isWanted != isSampling
        isSampling = isWanted
        lock.unlock()
        guard changes else { return }
        guard isWanted else {
            motionManager.stopDeviceMotionUpdates()
            return
        }
        motionManager.deviceMotionUpdateInterval = RollTrack.sampleInterval
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.deliver(motion.gravity)
        }
    }

    private func deliver(_ gravity: CMAcceleration) {
        lock.lock()
        let observer = gravityObserver
        let isRecording = self.isRecording
        lock.unlock()
        observer?(gravity)
        if isRecording?() == true {
            append(gravity: gravity)
        }
    }

    /// One gravity sample, stamped with the host clock at delivery — the few milliseconds
    /// of motion latency are nothing next to the window the editor averages over — and
    /// pushed later only as far as the previous group's end.
    private func append(gravity: CMAcceleration) {
        lock.lock()
        let input = self.input
        let geometry = self.geometry
        let previousEnd = lastEnd
        lock.unlock()
        guard let input, let geometry,
              let tilt = RollTrack.tilt(
                  gravityX: gravity.x, gravityY: gravity.y,
                  videoRotationDegrees: geometry.videoRotationDegrees,
                  isFrontCamera: geometry.isFrontCamera)
        else { return }
        var start = CMClockGetTime(hostClock)
        if previousEnd.isValid, CMTimeCompare(start, previousEnd) < 0 {
            start = previousEnd
        }
        let group = RollTrack.timedGroup(tilt: tilt, start: start)
        // A rejected group (the output not recording at this instant, say) is just a
        // missing sample; the next one stands on its own.
        guard (try? input.append(group)) != nil else { return }
        lock.lock()
        lastEnd = CMTimeAdd(start, group.timeRange.duration)
        lock.unlock()
    }
}
