import Foundation

/// Rebases live presentation timestamps, which are on the capture session's clock, onto the
/// written file's timeline, which starts near zero at the first sample the movie output wrote.
///
/// The anchor is the first timestamp offered after recording is confirmed started, per
/// docs/LIVE_POSE.md "Timestamps". That is within a frame or two of the file's first sample —
/// under 10 ms at 240 fps — which is inside the 100 ms resolution the pipeline samples at.
struct LivePoseTimestampAnchor: Equatable, Sendable {
    private(set) var anchor: TimeInterval?

    /// `presentationTime` expressed relative to the anchor; the first call defines the anchor and
    /// returns zero.
    mutating func fileRelative(_ presentationTime: TimeInterval) -> TimeInterval {
        let anchor = self.anchor ?? presentationTime
        self.anchor = anchor
        return presentationTime - anchor
    }
}
