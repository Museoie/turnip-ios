import CoreGraphics
import Foundation

/// Auto follow's zoom (`docs/DESIGN.md` step 6): how wide the follow crop is at each pose sample,
/// from the room the athlete needs there.
///
/// The room is the static calculator's box around one sample's joints, with the still crop's
/// padding. Followed sample by sample it would breathe with every tuck and extension, so:
/// 1. **Reach.** Each sample takes the largest room within `reachSeconds` either side of it, so
///    the crop widens before a limb would leave it and stays wide until the limb is back.
/// 2. **Dead zone.** The width holds until the reach strays from it by more than `deadZone`, in
///    proportion, and then steps to the reach: smaller changes are ignored.
/// 3. **Smoothing.** Each step becomes an ease, a Gaussian of `smoothingSeconds` standard
///    deviation. A widening one (a zoom out) is centered on its step, which the reach already
///    puts ahead of the need. A narrowing one (a zoom in) is `1 / zoomInSpeed` times as wide, so
///    the crop closes in at most `zoomInSpeed` times as fast as it opens out, and is centered one
///    of its own deviations after its step, so it barely starts before the reach has let go.
///
/// Widths move in proportion (on their logarithm), so 500 to 600 px moves like 1,000 to 1,200.
/// The numbers were tuned on the evaluation windows (`docs/DESIGN.md` step 6, "Zoom tuning").
struct ZoomEnvelope: Sendable {
    var reachSeconds: TimeInterval = 0.8
    var smoothingSeconds: TimeInterval = 0.8
    var deadZone: Double = 0.12
    var zoomInSpeed: Double = 0.5
    /// How far, in proportion, Auto follow's reduced zoom curve may stray from a sample's own width
    /// before a keyframe goes in at that sample (`AutoFollow`).
    var zoomTolerance: CGFloat = 0.05

    /// One width per sample at `times` (ascending), in `needs`' units, from each sample's room
    /// (`nil` where a sample located nothing: it takes its neighbours'). Empty when none located
    /// anything.
    func widths(times: [TimeInterval], needs: [CGFloat?]) -> [CGFloat] {
        guard let levels = levels(times: times, needs: needs), let first = levels.first else { return [] }
        let steps = (1..<max(levels.count, 1)).compactMap { index -> (time: TimeInterval, change: Double)? in
            let change = levels[index] - levels[index - 1]
            return change == 0 ? nil : ((times[index - 1] + times[index]) / 2, change)
        }
        return times.map { time in
            var level = first
            for step in steps {
                let opens = step.change > 0
                let deviation = opens ? smoothingSeconds : smoothingSeconds / zoomInSpeed
                let middle = opens ? step.time : step.time + deviation
                level += step.change * 0.5 * (1 + erf((time - middle) / (deviation * 2.0.squareRoot())))
            }
            return CGFloat(exp(level))
        }
    }

    /// How many times the dead zone lets the width change over these samples: how often the crop
    /// zooms.
    func zoomCount(times: [TimeInterval], needs: [CGFloat?]) -> Int {
        guard let levels = levels(times: times, needs: needs) else { return 0 }
        return zip(levels, levels.dropFirst()).filter { $0 != $1 }.count
    }

    /// The logarithm of each sample's reach after the dead zone, a step function.
    private func levels(times: [TimeInterval], needs: [CGFloat?]) -> [Double]? {
        guard times.count == needs.count else { return nil }
        let located = needs.indices.filter { (needs[$0] ?? 0) > 0 }
        guard !located.isEmpty else { return nil }
        let logs: [Double] = times.indices.map { index in
            let before = located.last { $0 <= index }, after = located.first { $0 >= index }
            func value(_ sample: Int) -> Double { log(Double(needs[sample] ?? 1)) }
            switch (before, after) {
            case let (before?, after?) where before != after:
                let progress = (times[index] - times[before]) / max(times[after] - times[before], 1e-9)
                return value(before) + (value(after) - value(before)) * progress
            case let (before?, _):
                return value(before)
            case let (_, after?):
                return value(after)
            default:
                return 0
            }
        }
        let reach = times.indices.map { index in
            times.indices
                .filter { abs(times[$0] - times[index]) <= reachSeconds + 1e-9 }
                .map { logs[$0] }
                .max() ?? logs[index]
        }
        let threshold = log(1 + deadZone)
        var level = reach[0]
        return reach.map { value in
            if abs(value - level) > threshold { level = value }
            return level
        }
    }
}
