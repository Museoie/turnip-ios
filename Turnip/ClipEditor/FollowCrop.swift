import CoreGraphics
import Foundation

/// The two ways a clip's crop can frame it (`docs/UIUX.md` § "Two framing modes, Still and
/// Follow"): one framing held for the whole clip, or a crop that moves with the athlete.
enum FramingMode: Hashable, Sendable {
    case still
    case follow
}

/// One moment of a follow crop: where the crop's center sits in the source video then.
struct FollowKeyframe: Hashable, Sendable {
    /// Source time, in seconds.
    var time: TimeInterval
    /// The crop's center, in the displayed (upright) frame's pixels.
    var center: CGPoint
    /// Where Auto follow put this keyframe; `nil` for one the user added. It differs from
    /// `center` once the user has moved it, and removing a moved keyframe returns it here.
    var autoCenter: CGPoint?

    /// True while the keyframe sits where Auto follow put it — drawn hollow, and replaced by
    /// the next Auto follow.
    var isAutoFollows: Bool {
        autoCenter == center
    }
}

/// A crop that moves with the athlete (`docs/DESIGN.md` step 6, "Follow crop in the editor"):
/// a few keyframes of the crop's center, and one zoom and one level for the whole clip,
/// applied about the moving center. A zoom per keyframe would make the clip breathe in and
/// out, and a turn per keyframe would tilt the horizon partway through.
///
/// Between keyframes the center moves on one monotone cubic through all of them
/// (`MonotoneCubic`), which eases out of the first keyframe and into the last and passes
/// through the ones between without stopping; before the first and after the last it holds.
struct FollowCrop: Hashable, Sendable {
    /// The zoom, against the clip's crop rect filling the marker — `CropAdjustment.scale`'s
    /// meaning, so the two modes zoom alike.
    var scale: CGFloat
    var rotationRadians: Double
    /// In time order.
    var keyframes: [FollowKeyframe]
    /// Where the crop holds while there are no keyframes, in displayed pixels: the frame's
    /// own center after Reset follow.
    var restingCenter: CGPoint
    /// True while this is exactly what Auto follow wrote, so its button offers Reset follow.
    /// Any pinch, turn, drag or keyframe change clears it; a trim and Auto rotate don't.
    var isAutoFollow: Bool

    /// The crop's center over time.
    var path: FollowPath {
        FollowPath(keyframes: keyframes, restingCenter: restingCenter)
    }

    /// True when every keyframe is still where Auto follow put it — what lets a trim re-track
    /// the window. A follow crop with no keyframes has nothing Auto follow wrote.
    var isUntouchedAutoFollow: Bool {
        !keyframes.isEmpty && keyframes.allSatisfy(\.isAutoFollows)
    }
}

/// The center a follow crop draws at each moment, built once from its keyframes so a caller
/// sampling every frame doesn't refit the curve per sample.
struct FollowPath: Sendable {
    private let x: MonotoneCubic?
    private let y: MonotoneCubic?
    private let restingCenter: CGPoint
    /// The span over which the center moves: from the first keyframe to the last. Outside it
    /// the center holds. `nil` with fewer than two keyframes.
    let movingSpan: ClosedRange<TimeInterval>?

    init(keyframes: [FollowKeyframe], restingCenter: CGPoint) {
        self.restingCenter = restingCenter
        let sorted = keyframes.sorted { $0.time < $1.time }
        let times = sorted.map(\.time)
        x = sorted.isEmpty ? nil : MonotoneCubic(times: times, values: sorted.map { Double($0.center.x) })
        y = sorted.isEmpty ? nil : MonotoneCubic(times: times, values: sorted.map { Double($0.center.y) })
        if let first = times.first, let last = times.last, last > first {
            movingSpan = first...last
        } else {
            movingSpan = nil
        }
    }

    func center(at time: TimeInterval) -> CGPoint {
        guard let x, let y else { return restingCenter }
        return CGPoint(x: x.value(at: time), y: y.value(at: time))
    }
}

/// A monotone cubic Hermite curve through `(time, value)` knots — Fritsch–Carlson's family,
/// with the weighted harmonic mean of the neighbouring slopes as each knot's tangent (the
/// form that stays monotone on uneven spacing). It never swings past a knot: between two
/// knots it stays within their values, and at a knot where the value turns back its speed is
/// zero. Its speed is also zero at the first and last knot, so a crop holding still before
/// and after them eases into and out of the move; with two knots it is the ease-in-out cubic.
/// Before the first knot and after the last it holds that knot's value.
struct MonotoneCubic: Sendable {
    private let times: [Double]
    private let values: [Double]
    private let tangents: [Double]

    /// `times` ascending; knots at the same time keep the first.
    init(times: [Double], values: [Double]) {
        precondition(times.count == values.count, "one value per knot")
        var knotTimes: [Double] = [], knotValues: [Double] = []
        for (time, value) in zip(times, values) where knotTimes.last.map({ time > $0 }) ?? true {
            knotTimes.append(time)
            knotValues.append(value)
        }
        self.times = knotTimes
        self.values = knotValues
        tangents = Self.tangents(times: knotTimes, values: knotValues)
    }

    func value(at time: Double) -> Double {
        guard let first = times.first, let last = times.last else { return 0 }
        if time <= first { return values[0] }
        if time >= last { return values[values.count - 1] }
        // The last knot at or before `time`; binary search, since export samples every frame.
        var low = 0, high = times.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if times[middle] <= time { low = middle } else { high = middle }
        }
        let span = times[high] - times[low]
        let progress = (time - times[low]) / span
        let squared = progress * progress, cubed = squared * progress
        let startWeight = 2 * cubed - 3 * squared + 1
        let startTangentWeight = cubed - 2 * squared + progress
        let endWeight = -2 * cubed + 3 * squared
        let endTangentWeight = cubed - squared
        return startWeight * values[low] + startTangentWeight * span * tangents[low]
            + endWeight * values[high] + endTangentWeight * span * tangents[high]
    }

    private static func tangents(times: [Double], values: [Double]) -> [Double] {
        let count = times.count
        guard count > 2 else { return Array(repeating: 0, count: count) }
        let spans = (0..<count - 1).map { times[$0 + 1] - times[$0] }
        let slopes = (0..<count - 1).map { (values[$0 + 1] - values[$0]) / spans[$0] }
        var result = Array(repeating: 0.0, count: count)
        for index in 1..<count - 1 {
            let before = slopes[index - 1], after = slopes[index]
            guard before * after > 0 else { continue }
            let beforeWeight = 2 * spans[index] + spans[index - 1]
            let afterWeight = spans[index] + 2 * spans[index - 1]
            result[index] = (beforeWeight + afterWeight) / (beforeWeight / before + afterWeight / after)
        }
        return result
    }
}
