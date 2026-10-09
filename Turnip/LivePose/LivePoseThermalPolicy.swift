import Foundation

/// How live inference reacts to the device heating up, per docs/LIVE_POSE.md "Thermal policy":
/// the recording is never touched, only the sampling is. `.serious` halves the sample rate;
/// `.critical` stops sampling for the rest of the recording.
enum LivePoseThermalPolicy {
    enum Response: Equatable, Sendable {
        /// Sample at the normal rate.
        case normal
        /// Sample at half the normal rate.
        case halved
        /// Sample nothing further for this recording.
        case stopped
    }

    static func response(to state: ProcessInfo.ThermalState) -> Response {
        switch state {
        case .nominal, .fair:
            return .normal
        case .serious:
            return .halved
        case .critical:
            return .stopped
        @unknown default:
            // A state this build does not know about is hotter than any it does; stopping is the
            // response that cannot make the recording worse.
            return .stopped
        }
    }

    /// The gap between kept samples under `response`, or nil when nothing should be kept.
    static func sampleInterval(base: TimeInterval, response: Response) -> TimeInterval? {
        switch response {
        case .normal:
            return base
        case .halved:
            return base * 2
        case .stopped:
            return nil
        }
    }
}
