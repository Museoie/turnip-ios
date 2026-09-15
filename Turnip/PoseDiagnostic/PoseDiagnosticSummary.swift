import Foundation

/// Run-level totals over every sampled frame, in the terms docs/DESIGN.md's escalation gate is
/// written in ("< 70% frames with usable pose" fires the model ladder).
///
/// "Usable pose" is the hip-midpoint rule the motion signal anchors on: both hips above
/// `PoseKeypoint.confidenceThreshold`. The per-row joint count is a finer-grained view of the
/// same threshold; this is the number that answers the gate.
struct PoseDiagnosticSummary: Equatable {
    let frameCount: Int
    let framesWithUsableHips: Int
    /// Mean of every frame's `averageConfidence`, so a frame weighs the same whatever its joints.
    let meanConfidence: Double

    init(results: [PoseFrameResult]) {
        frameCount = results.count
        framesWithUsableHips = results.filter(Self.hasUsableHips).count
        meanConfidence = results.isEmpty
            ? 0
            : results.reduce(0) { $0 + $1.averageConfidence } / Double(results.count)
    }

    var usableHipsFraction: Double {
        frameCount == 0 ? 0 : Double(framesWithUsableHips) / Double(frameCount)
    }

    static func hasUsableHips(_ result: PoseFrameResult) -> Bool {
        let usableNames = Set(
            result.keypoints
                .filter { $0.confidence > PoseKeypoint.confidenceThreshold }
                .map(\.name))
        return MotionSignalBuilder.hipKeypointNames.isSubset(of: usableNames)
    }
}

/// The screen's wording, in one place so the tests pin it: a row is one *sampled frame*, not a
/// detected trick, and "usable" always names its threshold.
enum PoseDiagnosticLabels {
    static let threshold = String(format: "%.2f", PoseKeypoint.confidenceThreshold)

    /// Shown before a run, where the row stream is otherwise easy to read as the video being cut
    /// into pieces.
    static let explanation =
        "Samples about \(VideoFrameSampler.targetSamplesPerSecond) frames per second and lists one "
        + "row per sampled frame — a 12-second clip yields about 120 rows. Tap a row to jump the "
        + "player to that frame; joints above \(threshold) confidence draw filled, the rest hollow."

    /// "t=0.12s · frame 3" — time first, since that is what the player seeks to; the source
    /// frame index second.
    static func rowTitle(for result: PoseFrameResult) -> String {
        "t=\(String(format: "%.2f", result.timestamp))s · frame \(result.frameIndex)"
    }

    /// "9 of 17 joints above 0.30 confidence · avg 0.41".
    static func rowDetail(for result: PoseFrameResult) -> String {
        "\(result.usableKeypointCount) of \(PoseKeypoint.names.count) joints above \(threshold) confidence"
            + " · avg \(String(format: "%.2f", result.averageConfidence))"
    }

    /// "120 frames sampled · 84 (70%) with both hips above 0.30 · mean confidence 0.52".
    static func summary(_ summary: PoseDiagnosticSummary) -> String {
        let percent = Int((summary.usableHipsFraction * 100).rounded())
        return "\(summary.frameCount) frames sampled · \(summary.framesWithUsableHips) (\(percent)%) "
            + "with both hips above \(threshold) · mean confidence "
            + String(format: "%.2f", summary.meanConfidence)
    }
}
