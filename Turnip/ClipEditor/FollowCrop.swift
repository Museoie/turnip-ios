import CoreGraphics
import Foundation

/// The two ways a clip's crop can frame it (`docs/UIUX.md` § "Two framing modes, Still and
/// Follow"): one framing held for the whole clip, or a crop that moves with the athlete.
enum FramingMode: Hashable, Sendable {
    case still
    case follow
}

/// A follow crop's framing at one moment: the source point at the marker's center, and the
/// zoom and turn about it.
struct FollowFraming: Hashable, Sendable {
    /// In the displayed (upright) frame's pixels.
    var center: CGPoint
    /// Against the clip's crop rect filling the marker — `CropAdjustment.scale`'s meaning, so the
    /// two modes zoom alike.
    var scale: CGFloat
    var rotationRadians: Double
}

/// One moment of a follow crop: the whole crop then, as a still crop holds it for the clip —
/// where the video sits under the marker, its zoom and its turn.
struct FollowKeyframe: Hashable, Sendable {
    /// Source time, in seconds.
    var time: TimeInterval
    /// The crop's center, in the displayed (upright) frame's pixels.
    var center: CGPoint
    /// The zoom (`FollowFraming.scale`).
    var scale: CGFloat
    var rotationRadians: Double
    /// Where Auto follow put this keyframe, and the zoom and turn it gave it; `nil` for one the
    /// user added. They differ from `center`, `scale` and `rotationRadians` once the user has
    /// changed it, and removing a changed keyframe returns it to all three.
    var autoCenter: CGPoint?
    var autoScale: CGFloat?
    var autoRotationRadians: Double?

    init(
        time: TimeInterval, center: CGPoint, scale: CGFloat = 1, rotationRadians: Double = 0,
        autoCenter: CGPoint? = nil, autoScale: CGFloat? = nil, autoRotationRadians: Double? = nil
    ) {
        self.time = time
        self.center = center
        self.scale = scale
        self.rotationRadians = rotationRadians
        self.autoCenter = autoCenter
        self.autoScale = autoScale
        self.autoRotationRadians = autoRotationRadians
    }

    /// A keyframe at `framing`; marked as Auto follow's when `isAuto`.
    init(time: TimeInterval, framing: FollowFraming, isAuto: Bool = false) {
        self.init(
            time: time, center: framing.center, scale: framing.scale, rotationRadians: framing.rotationRadians,
            autoCenter: isAuto ? framing.center : nil, autoScale: isAuto ? framing.scale : nil,
            autoRotationRadians: isAuto ? framing.rotationRadians : nil)
    }

    var framing: FollowFraming {
        get { FollowFraming(center: center, scale: scale, rotationRadians: rotationRadians) }
        set {
            center = newValue.center
            scale = newValue.scale
            rotationRadians = newValue.rotationRadians
        }
    }

    /// Auto follow's framing for this keyframe; `nil` for one the user added.
    var autoFraming: FollowFraming? {
        guard let autoCenter, let autoScale, let autoRotationRadians else { return nil }
        return FollowFraming(center: autoCenter, scale: autoScale, rotationRadians: autoRotationRadians)
    }

    /// True while the keyframe is exactly what Auto follow wrote — drawn hollow, and replaced by
    /// the next Auto follow. A change to its position, zoom or turn fills it.
    var isAutoFollows: Bool {
        autoFraming == framing
    }
}

/// A crop that moves with the athlete (`docs/DESIGN.md` step 6, "Follow crop in the editor"):
/// a few keyframes, each the crop's center, zoom and turn at one moment. Every frame is a crop
/// of the marker's ratio, zoomed and turned about its moving center.
///
/// Between keyframes the center's two axes, the zoom (in proportion) and the turn each move on
/// a monotone cubic through all of them (`MonotoneCubic`), which eases out of the first keyframe
/// and into the last and passes through the ones between without stopping; before the first and
/// after the last the crop holds.
struct FollowCrop: Hashable, Sendable {
    /// In time order.
    var keyframes: [FollowKeyframe]
    /// Where the crop holds while there are no keyframes: after Reset follow, the frame's own
    /// center at the zoom that shows all of it.
    var resting: FollowFraming
    /// True while this is exactly what Auto follow wrote, so its button offers Reset follow.
    /// Any pinch, turn, drag or keyframe change clears it; a trim and Auto rotate don't.
    var isAutoFollow: Bool

    /// The crop's framing over time.
    var path: FollowPath {
        FollowPath(keyframes: keyframes, resting: resting)
    }

    /// True when every keyframe is still what Auto follow wrote — what lets a trim re-track the
    /// window. A follow crop with no keyframes has nothing Auto follow wrote.
    var isUntouchedAutoFollow: Bool {
        !keyframes.isEmpty && keyframes.allSatisfy(\.isAutoFollows)
    }

    /// Turns every keyframe and the resting framing to `radians`: Auto rotate and Reset rotate.
    /// A keyframe Auto follow wrote takes the turn as Auto follow's too, as a turn leaves Auto
    /// crop's fit on, so it stays hollow and a removal keeps the clip's level.
    mutating func setRotation(_ radians: Double) {
        resting.rotationRadians = radians
        for index in keyframes.indices {
            keyframes[index].rotationRadians = radians
            if keyframes[index].autoRotationRadians != nil {
                keyframes[index].autoRotationRadians = radians
            }
        }
    }
}

/// The framing a follow crop draws at each moment, built once from its keyframes so a caller
/// sampling every frame doesn't refit the curves per sample.
struct FollowPath: Sendable {
    private let x: MonotoneCubic?
    private let y: MonotoneCubic?
    /// On the scale's logarithm, so equal zoom ratios take equal time: 1× to 2× as long as 2× to 4×.
    private let logScale: MonotoneCubic?
    /// Unwrapped: the turn moves between the keyframes' own values, a whole turn included, never
    /// the shorter way round.
    private let rotation: MonotoneCubic?
    private let resting: FollowFraming
    /// The span over which the crop moves: from the first keyframe to the last. Outside it the
    /// crop holds. `nil` with fewer than two keyframes.
    let movingSpan: ClosedRange<TimeInterval>?

    init(keyframes: [FollowKeyframe], resting: FollowFraming) {
        self.resting = resting
        let sorted = keyframes.sorted { $0.time < $1.time }
        let times = sorted.map(\.time)
        func curve(_ value: (FollowKeyframe) -> Double) -> MonotoneCubic? {
            sorted.isEmpty ? nil : MonotoneCubic(times: times, values: sorted.map(value))
        }
        x = curve { Double($0.center.x) }
        y = curve { Double($0.center.y) }
        logScale = curve { log(Double(max($0.scale, .leastNormalMagnitude))) }
        rotation = curve { $0.rotationRadians }
        if let first = times.first, let last = times.last, last > first {
            movingSpan = first...last
        } else {
            movingSpan = nil
        }
    }

    func framing(at time: TimeInterval) -> FollowFraming {
        guard let x, let y, let logScale, let rotation else { return resting }
        return FollowFraming(
            center: CGPoint(x: x.value(at: time), y: y.value(at: time)),
            scale: CGFloat(exp(logScale.value(at: time))),
            rotationRadians: rotation.value(at: time))
    }

    func center(at time: TimeInterval) -> CGPoint {
        guard let x, let y else { return resting.center }
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
