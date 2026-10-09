import Foundation

/// Running mean and maximum of a set of durations, for the two per-sample costs the acceptance
/// gate needs to tell apart: preprocess (on the capture queue) and inference (on the model actor).
/// Without both, a slow preprocess loop reads as a slow model.
struct DurationStats: Equatable, Sendable {
    private(set) var count = 0
    private(set) var total: TimeInterval = 0
    private(set) var maximum: TimeInterval = 0

    mutating func record(_ duration: TimeInterval) {
        count += 1
        total += duration
        maximum = max(maximum, duration)
    }

    var mean: TimeInterval {
        count == 0 ? 0 : total / Double(count)
    }

    /// "6.1 ms avg / 12.0 max".
    var millisecondsLabel: String {
        String(format: "%.1f ms avg / %.1f max", mean * 1000, maximum * 1000)
    }
}

/// What one live-inference recording measured, in the terms docs/LIVE_POSE.md "Acceptance gate"
/// is written in. Filled in by the capture side (`LivePoseFrameTap`) and the inference side
/// (`LivePoseRecording`), logged by `LivePoseLogger`, and read by `LivePoseCoverage`.
struct LivePoseMetrics: Equatable, Sendable {
    /// Data-output callbacks received while the movie output was recording.
    var framesDelivered = 0
    /// Frames the gate admitted and the capture queue reduced to tensors.
    var framesKept = 0
    /// Frames the model actually scored. Below `framesKept` when the queue overflowed.
    var framesInferred = 0
    /// Frames the capture output discarded because the delegate was still busy with an earlier one.
    var lateFrameDrops = 0
    /// Frames whose letterbox or repack threw; they never reached the queue.
    var preprocessFailures = 0
    var queueDrops = 0
    var maxQueueDepth = 0
    /// File-relative timestamp of the last frame delivered while recording.
    var recordingDuration: TimeInterval = 0
    var secondsAtSerious: TimeInterval = 0
    var stoppedForThermal = false
    /// The recording was abandoned before its consumer drained, so there is nothing to review. An
    /// inference failure ends the drain too, but is reported through `LivePoseOutcome.errorMessage`.
    var wasCancelled = false
    var preprocess = DurationStats()
    var inference = DurationStats()

    var samplesPerSecond: Double {
        recordingDuration > 0 ? Double(framesKept) / recordingDuration : 0
    }

    /// One log line per recording, gate figures first.
    var summaryLine: String {
        var parts = [
            "Live: \(framesKept) samples in \(String(format: "%.1f", recordingDuration)) s "
                + "(\(String(format: "%.1f", samplesPerSecond))/s)",
            "inferred \(framesInferred)",
            "queue drops \(queueDrops) (max depth \(maxQueueDepth))",
            "late frames \(lateFrameDrops)",
            "preprocess \(preprocess.millisecondsLabel)",
            "inference \(inference.millisecondsLabel)",
            String(format: "%.0f s at serious", secondsAtSerious)
        ]
        if preprocessFailures > 0 {
            parts.append("preprocess failures \(preprocessFailures)")
        }
        if stoppedForThermal {
            parts.append("stopped: critical thermal state")
        }
        if wasCancelled {
            parts.append("cancelled")
        }
        return parts.joined(separator: " · ")
    }
}

/// Everything one live-inference recording produced, available once the consumer has drained.
struct LivePoseOutcome: Sendable {
    /// In timestamp order: the capture callback is serial and the queue is FIFO.
    let results: [PoseFrameResult]
    let metrics: LivePoseMetrics
    let errorMessage: String?
}
