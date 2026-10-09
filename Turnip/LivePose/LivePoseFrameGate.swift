import Foundation

/// Decides which live frames are kept for inference. Keyed on presentation time, not on a frame
/// counter: with `alwaysDiscardsLateVideoFrames` on, the capture output silently skips the frames
/// that arrive while a kept frame is still being preprocessed, so counting delivered frames would
/// undersample by however many were skipped. Time cannot be skipped.
///
/// Kept frames land on a grid one interval apart, anchored at the first kept frame. A frame that
/// arrives after a gap longer than one interval (a thermal stop lifting, a long stall) re-anchors
/// the grid rather than admitting a burst of frames to "catch up". A change of interval applies
/// from the last kept frame, so halving the rate under thermal pressure takes effect at once.
///
/// `defaultInterval` is `1 / VideoFrameSampler.targetSamplesPerSecond`; `LivePoseFrameTap.arm`
/// passes `1 / sampleRate` instead when armed with the Settings screen's analysis granularity,
/// so the live path samples at whatever rate the file path is configured for, not always the
/// shipped default. Thermal backoff widens whichever interval is in force.
struct LivePoseFrameGate: Equatable, Sendable {
    static let defaultInterval = 1.0 / Double(VideoFrameSampler.targetSamplesPerSecond)

    /// Slack for a frame whose timestamp rounds to a hair before its slot. Capture timestamps are
    /// milliseconds apart, so a microsecond cannot admit a neighbouring frame by mistake.
    static let slotTolerance: TimeInterval = 1e-6

    let baseInterval: TimeInterval
    var thermal: LivePoseThermalPolicy.Response = .normal
    /// Grid position of the last kept frame.
    private var lastSlot: TimeInterval?

    init(baseInterval: TimeInterval = LivePoseFrameGate.defaultInterval) {
        precondition(baseInterval > 0, "LivePoseFrameGate needs a positive interval (got \(baseInterval))")
        self.baseInterval = baseInterval
    }

    /// The interval currently in force, or nil while thermal policy has stopped sampling.
    var currentInterval: TimeInterval? {
        LivePoseThermalPolicy.sampleInterval(base: baseInterval, response: thermal)
    }

    /// True when the frame at `presentationTime` should be kept. Frames must arrive in
    /// presentation order.
    mutating func admits(presentationTime: TimeInterval) -> Bool {
        guard let interval = currentInterval else { return false }
        guard let lastSlot else {
            self.lastSlot = presentationTime
            return true
        }
        let nextSlot = lastSlot + interval
        if presentationTime < nextSlot - Self.slotTolerance {
            return false
        }
        self.lastSlot = presentationTime - nextSlot < interval ? nextSlot : presentationTime
        return true
    }
}
