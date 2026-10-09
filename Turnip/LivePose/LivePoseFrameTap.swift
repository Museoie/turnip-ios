// AVFoundation predates Swift concurrency and isn't Sendable-audited; the delegate callbacks
// below run on the output's own serial queue, and everything they touch is behind a lock.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// The capture side of live pose inference: an `AVCaptureVideoDataOutput` that sits on the
/// session next to the movie output, and its delegate.
///
/// Per docs/LIVE_POSE.md "Capture side": the output delivers the device's native 420v frames on a
/// dedicated serial queue and discards frames that arrive while the delegate is busy. While a
/// recording is confirmed started, every delivered frame is timestamped against the file's
/// timeline and offered to a `LivePoseFrameGate`; a kept frame is reduced to its model input right
/// here, in the callback, and pushed to the recording's channel. The sample buffer is never
/// retained past the callback — the output recycles them from a small pool, and holding one
/// stalls delivery.
///
/// `@unchecked Sendable`: the only mutable state is the current session, held in an
/// `OSAllocatedUnfairLock`; the output and queue are immutable after `init`.
final class LivePoseFrameTap: NSObject, @unchecked Sendable {
    let output = AVCaptureVideoDataOutput()

    private enum Phase {
        /// Record was tapped; the movie output has not confirmed it is writing yet.
        case armed
        case recording
    }

    /// One recording's capture-side state. Replaced wholesale on each `arm`.
    private struct Session {
        let recording: LivePoseRecording
        let preparer: PoseInputPreparer
        let frameRate: Double
        /// Clockwise degrees, `videoRotationAngle` terms, from the data connection to the movie
        /// connection — passed to `preparer.prepare` so every kept frame is uprighted before it is
        /// letterboxed into the model's input.
        let rotationDegrees: Int
        var phase = Phase.armed
        var gate: LivePoseFrameGate
        var anchor = LivePoseTimestampAnchor()
        var metrics = LivePoseMetrics()
        /// System uptime when the thermal state last entered `.serious`; nil while it is not there.
        var seriousSince: TimeInterval?

        mutating func apply(_ response: LivePoseThermalPolicy.Response, at now: TimeInterval) {
            gate.thermal = response
            if response == .stopped {
                metrics.stoppedForThermal = true
            }
            switch (response, seriousSince) {
            case (.halved, nil):
                seriousSince = now
            case (.normal, let since?), (.stopped, let since?):
                metrics.secondsAtSerious += now - since
                seriousSince = nil
            default:
                break
            }
        }

        mutating func closeThermalAccounting(at now: TimeInterval) {
            if let since = seriousSince {
                metrics.secondsAtSerious += now - since
                seriousSince = nil
            }
        }
    }

    /// What the callback needs once it has decided to keep a frame, copied out so the letterbox
    /// runs outside the lock.
    private struct Admission {
        let recording: LivePoseRecording
        let preparer: PoseInputPreparer
        let frameIndex: Int
        let timestamp: TimeInterval
        let rotationDegrees: Int
    }

    private let captureQueue = DispatchQueue(label: "com.hoiekim.turnip.livepose.capture", qos: .userInitiated)
    private let session = OSAllocatedUnfairLock<Session?>(initialState: nil)

    override init() {
        super.init()
        // An empty dictionary asks for the device's native format (420v here). `nil` would ask for
        // a default *uncompressed* format and have the ISP convert every frame, kept or not.
        output.videoSettings = [:]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Record was tapped. Frames are counted from `recordingDidStart()`, not from here.
    /// `sampleRate` is the Settings screen's granularity control
    /// (`TurnipSettings.analysisGranularity`) — it sets the gate's base interval to
    /// `1 / sampleRate` so the live path samples at the same rate the user configured for the
    /// file path, rather than always the shipped default.
    func arm(
        recording: LivePoseRecording, preparer: PoseInputPreparer, frameRate: Double, rotationDegrees: Int,
        sampleRate: Int = VideoFrameSampler.targetSamplesPerSecond
    ) {
        let gate = LivePoseFrameGate(baseInterval: 1.0 / Double(sampleRate))
        var fresh = Session(
            recording: recording, preparer: preparer, frameRate: frameRate,
            rotationDegrees: rotationDegrees, gate: gate)
        fresh.apply(
            LivePoseThermalPolicy.response(to: ProcessInfo.processInfo.thermalState),
            at: ProcessInfo.processInfo.systemUptime)
        session.withLock { $0 = fresh }
    }

    /// The movie output confirmed it is writing; the next frame anchors the file timeline.
    func recordingDidStart() {
        session.withLock { $0?.phase = .recording }
    }

    /// The movie output finished. Hands the recording's consumer back so the caller can await its
    /// outcome; nil when nothing was armed.
    func endRecording() -> LivePoseRecording? {
        guard var ended = session.withLock({ session -> Session? in
            defer { session = nil }
            return session
        }) else { return nil }
        ended.closeThermalAccounting(at: ProcessInfo.processInfo.systemUptime)
        ended.recording.finish(producer: ended.metrics)
        return ended.recording
    }

    /// The recording is being abandoned (leaving the camera, session teardown): stop the consumer
    /// too, keeping what was measured.
    func cancel() {
        guard var cancelled = session.withLock({ session -> Session? in
            defer { session = nil }
            return session
        }) else { return }
        cancelled.closeThermalAccounting(at: ProcessInfo.processInfo.systemUptime)
        cancelled.recording.cancel(producer: cancelled.metrics)
    }

    /// Clockwise degrees the connection rotates its video by, in `videoRotationAngle` terms on
    /// every OS version so two connections can be compared.
    static func rotationDegrees(of connection: AVCaptureConnection) -> Int {
        if #available(iOS 17.0, *) {
            return Int(connection.videoRotationAngle.rounded())
        }
        switch connection.videoOrientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:
            return 180
        case .landscapeRight:
            return 0
        @unknown default:
            return 0
        }
    }

    @objc private func thermalStateDidChange(_ notification: Notification) {
        let response = LivePoseThermalPolicy.response(to: ProcessInfo.processInfo.thermalState)
        let now = ProcessInfo.processInfo.systemUptime
        session.withLock { $0?.apply(response, at: now) }
    }
}

extension LivePoseFrameTap: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard let admission = admit(presentationTime: presentationTime),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let input = try admission.preparer.prepare(pixelBuffer, rotationDegrees: admission.rotationDegrees)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            session.withLock { $0?.metrics.preprocess.record(elapsed) }
            admission.recording.channel.push(LivePoseSample(
                frameIndex: admission.frameIndex, timestamp: admission.timestamp, input: input))
        } catch {
            session.withLock { $0?.metrics.preprocessFailures += 1 }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        session.withLock { session in
            guard session?.phase == .recording else { return }
            session?.metrics.lateFrameDrops += 1
        }
    }

    /// The per-frame decision, all under the lock: anchor the timestamp, count the frame, ask the
    /// gate. Returns what the letterbox needs when the frame is kept.
    private func admit(presentationTime: TimeInterval) -> Admission? {
        session.withLock { session in
            guard var current = session, current.phase == .recording else { return nil }
            defer { session = current }
            current.metrics.framesDelivered += 1
            let timestamp = current.anchor.fileRelative(presentationTime)
            current.metrics.recordingDuration = timestamp
            guard current.gate.admits(presentationTime: timestamp) else { return nil }
            current.metrics.framesKept += 1
            return Admission(
                recording: current.recording,
                preparer: current.preparer,
                frameIndex: Int((timestamp * current.frameRate).rounded()),
                timestamp: timestamp,
                rotationDegrees: current.rotationDegrees)
        }
    }
}
