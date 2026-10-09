import CoreGraphics
import Foundation

/// Whether a live-inference recording scored the whole take the way the file path would have,
/// so its results can stand in for a post-recording analysis. Anything short of that sends the
/// take through Processing instead: the user must never get a worse clip list than the file
/// path gives, only a faster one.
enum LivePoseCoverage {
    /// How many samples a complete recording may be short of the grid's count and still count
    /// as complete: the first slot at zero is a frame or two after the file's own start, and the
    /// last slot can fall in the frames after Stop that the tap never sees.
    static let sampleTolerance = 2

    /// The number of samples the frame gate lays down over `duration` at `interval`, counting the
    /// one at zero.
    static func expectedSamples(
        duration: TimeInterval, interval: TimeInterval = LivePoseFrameGate.defaultInterval
    ) -> Int {
        guard duration > 0, interval > 0 else { return 0 }
        return Int((duration / interval).rounded(.down)) + 1
    }

    /// True when the recording's results cover it end to end at `interval`'s rate (the caller's
    /// configured granularity, not necessarily the shipped default). Any time under `.serious`
    /// disqualifies: the detector's thresholds are per sample at the configured rate, and a
    /// halved rate changes what "three sustained samples" means.
    static func isComplete(
        _ outcome: LivePoseOutcome, interval: TimeInterval = LivePoseFrameGate.defaultInterval
    ) -> Bool {
        let metrics = outcome.metrics
        guard outcome.errorMessage == nil,
              !metrics.wasCancelled,
              !metrics.stoppedForThermal,
              metrics.secondsAtSerious == 0,
              metrics.queueDrops == 0,
              metrics.preprocessFailures == 0,
              metrics.framesInferred == metrics.framesKept,
              metrics.framesInferred > 0
        else { return false }
        let expected = expectedSamples(duration: metrics.recordingDuration, interval: interval)
        return metrics.framesInferred >= expected - sampleTolerance
    }

    /// The pixel size the live keypoints are normalized against, in the file's display
    /// orientation: the sensor's dimensions, transposed when the movie output's connection
    /// turns the picture a quarter-turn. This is what the crop step measures its aspect ratio
    /// and minimum extent against, the way the file path uses the composition's render size.
    static func renderedPixelSize(sensorWidth: Int32, sensorHeight: Int32, movieRotationDegrees: Int) -> CGSize {
        let quarterTurn = (movieRotationDegrees % 180 + 180) % 180 == 90
        return quarterTurn
            ? CGSize(width: CGFloat(sensorHeight), height: CGFloat(sensorWidth))
            : CGSize(width: CGFloat(sensorWidth), height: CGFloat(sensorHeight))
    }
}
