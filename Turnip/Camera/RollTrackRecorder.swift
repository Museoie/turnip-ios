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
        lastEnd = .invalid
        lock.unlock()
        motionManager.deviceMotionUpdateInterval = RollTrack.sampleInterval
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion, isRecording() else { return }
            self.append(gravity: motion.gravity)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        lock.lock()
        geometry = nil
        lock.unlock()
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
                  gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z,
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
