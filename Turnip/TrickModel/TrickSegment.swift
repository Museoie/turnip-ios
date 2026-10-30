import Foundation

/// One trick the model found (`MODEL_CONTRACT.md` §3.2): canonical 10 Hz frames, end exclusive,
/// the confidence that a trick is there, and every name it offers, highest first, each with its
/// own confidence.
struct TrickSegment: Equatable, Sendable {
    var startFrame: Int
    var endFrame: Int
    var score: Float
    var trickNames: [String]
    /// One per entry of `trickNames`, in the same order.
    var nameScores: [Float]

    /// The segment's window in seconds of the canonical timeline, which starts with the video.
    var window: TrickWindow {
        let rate = Double(ContributionPose.canonicalRate)
        return TrickWindow(startTime: Double(startFrame) / rate, endTime: Double(endFrame) / rate)
    }
}

/// What decoding the baseline's window classifier needs to know about it (`MODEL_CONTRACT.md`
/// §3.2.1): its classes and the window grid its rows sit on.
struct TrickModelDescriptor: Equatable, Sendable {
    let classes: [String]
    let windowFrames: Int
    let windowStride: Int
    var backgroundClass = "background"
    /// What joins a combo's names into one class, `"cork+gainer"`.
    var comboSeparator: Character = "+"

    /// The number of windows over `frameCount` canonical frames; 0 when even one doesn't fit.
    func windowCount(frameCount: Int) -> Int {
        frameCount < windowFrames ? 0 : (frameCount - windowFrames) / windowStride + 1
    }

    /// Decodes `window_probs`, one softmax row per window, into segments: each window takes its
    /// most probable class, and a run of consecutive windows with the same class other than the
    /// background becomes one segment from the first window's start to the last one's end. This is
    /// the decoding training scores with. A segment's `score` is the mean of its winning class's
    /// probability over the run, and each of its names carries that same score, since a combo's
    /// names share one class.
    func segments(windowProbabilities rows: [[Float]]) -> [TrickSegment] {
        /// Consecutive windows won by one class: the first and last window, and the sum of the
        /// class's probability over them.
        struct Run {
            let label: String
            let first: Int
            var last: Int
            var total: Float
        }
        var segments: [TrickSegment] = []
        var run: Run?

        func closeRun() {
            guard let open = run, open.label != backgroundClass else { return }
            let score = open.total / Float(open.last - open.first + 1)
            let names = open.label.split(separator: comboSeparator).map(String.init)
            segments.append(TrickSegment(
                startFrame: open.first * windowStride,
                endFrame: open.last * windowStride + windowFrames,
                score: score,
                trickNames: names,
                nameScores: names.map { _ in score }))
        }

        for (index, row) in rows.enumerated() {
            // `max(by:)` keeps the first of equal maxima, as numpy's argmax does in training.
            guard let best = row.indices.max(by: { row[$0] < row[$1] }),
                  classes.indices.contains(best)
            else { continue }
            let label = classes[best]
            if var open = run, open.label == label, open.last == index - 1 {
                open.last = index
                open.total += row[best]
                run = open
            } else {
                closeRun()
                run = Run(label: label, first: index, last: index, total: row[best])
            }
        }
        closeRun()
        return segments
    }
}
