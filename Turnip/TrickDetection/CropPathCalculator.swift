import CoreGraphics
import Foundation

/// Where the crop sits at one moment of a trick window, in the decoded frames' normalized space.
struct CropKeyframe: Hashable, Sendable {
    let time: TimeInterval
    let rect: NormalizedRect
}

/// A crop that moves over a trick window to follow the athlete. Every keyframe holds a rect of
/// the same size, so the clip never zooms partway through; between keyframes the crop moves in a
/// straight line, which is what an `AVVideoCompositionLayerInstruction` transform ramp draws.
struct CropPath: Hashable, Sendable {
    /// In time order; never empty.
    let keyframes: [CropKeyframe]

    /// True when the crop never moves — an athlete who stays put gets a still frame, the same as
    /// a static crop.
    var isStatic: Bool {
        keyframes.allSatisfy { $0.rect == keyframes[0].rect }
    }

    /// The crop at `time`: linear between the keyframes either side, held at the first or last
    /// keyframe outside the path's span.
    func rect(at time: TimeInterval) -> NormalizedRect {
        guard let first = keyframes.first, let last = keyframes.last else {
            preconditionFailure("a crop path always holds at least one keyframe")
        }
        if time <= first.time { return first.rect }
        if time >= last.time { return last.rect }
        let nextIndex = keyframes.firstIndex { $0.time > time } ?? keyframes.count - 1
        let before = keyframes[nextIndex - 1]
        let after = keyframes[nextIndex]
        let span = after.time - before.time
        let progress = span > 0 ? Float((time - before.time) / span) : 1
        return NormalizedRect(
            minX: before.rect.minX + (after.rect.minX - before.rect.minX) * progress,
            maxX: before.rect.maxX + (after.rect.maxX - before.rect.maxX) * progress,
            minY: before.rect.minY + (after.rect.minY - before.rect.minY) * progress,
            maxY: before.rect.maxY + (after.rect.maxY - before.rect.maxY) * progress
        )
    }
}

/// Computes a crop that follows the athlete through one trick window — the moving counterpart of
/// `CropRectCalculator`'s one static rect (docs/DESIGN.md's pipeline step 6).
///
/// ```swift
/// let calculator = CropPathCalculator()
/// let path = calculator.cropPath(for: framesInWindow, renderedPixelSize: frame.renderSize)
/// let rectHalfwayThrough = path?.rect(at: (window.startTime + window.endTime) / 2)
/// ```
///
/// The path has one keyframe per pose sample. Three rules shape it:
/// - **One size for the whole clip**: the largest rect `rectCalculator` would draw around any
///   single sample, so the athlete fits every moment and the clip never zooms.
/// - **Smoothed, not chased**: each sample's athlete center comes from a line fitted through its
///   neighbours under a Gaussian in time. The whole window is known up front, so the fit looks
///   ahead as far as it looks back and the crop moves with the athlete rather than trailing them.
/// - **Still unless the athlete moves**: when the smoothed track stays within
///   `stillnessFraction` of the crop's size, the crop does not move at all.
///
/// Two corrections then apply to each keyframe, in this order: the crop shifts just far enough to
/// keep that sample's located joints inside it, and then slides inside the frame, which wins
/// when the two disagree.
struct CropPathCalculator: Sendable {
    /// Draws the per-sample rect whose size and center the path is built from, so a path frames
    /// the athlete with the same padding, floor and aspect ratio as a static crop.
    let rectCalculator: CropRectCalculator
    /// Standard deviation, in seconds, of the Gaussian that weights each center's neighbours.
    /// Seconds rather than samples, so the analysis granularity setting changes how finely the
    /// athlete is sampled and not how smoothly the crop moves.
    let smoothingSeconds: TimeInterval
    /// How far the smoothed track may wander, as a fraction of the crop's size on each axis,
    /// before the crop follows it. Below this the athlete is standing still and the movement is
    /// keypoint jitter, which a moving crop would turn into camera shake.
    let stillnessFraction: Float

    init(rectCalculator: CropRectCalculator = CropRectCalculator(), smoothingSeconds: TimeInterval = 0.4,
         stillnessFraction: Float = 0.1) {
        precondition(smoothingSeconds > 0, "smoothingSeconds is a Gaussian's standard deviation and must be positive")
        precondition(stillnessFraction >= 0, "stillnessFraction is a distance and cannot be negative")
        self.rectCalculator = rectCalculator
        self.smoothingSeconds = smoothingSeconds
        self.stillnessFraction = stillnessFraction
    }

    /// `nil` when no frame holds a keypoint above the confidence threshold, or when the rendered
    /// frame size is unknown. Otherwise one keyframe per frame, in time order — a frame with no
    /// located keypoint still gets one, placed by its neighbours — or, before the first located
    /// sample or after the last, holding that end's keyframe.
    func cropPath(for frames: [PoseFrameResult], renderedPixelSize: CGSize) -> CropPath? {
        guard renderedPixelSize.width > 0, renderedPixelSize.height > 0 else { return nil }
        let samples = frames
            .sorted { $0.timestamp < $1.timestamp }
            .map { Sample(time: $0.timestamp, joints: Self.jointBox(in: $0)) }
        let located = samples.compactMap { locatedSample(from: $0, renderedPixelSize: renderedPixelSize) }
        guard !located.isEmpty else { return nil }

        let size = cropSize(fitting: located)
        // Evaluated inside the located span only: extending the fitted line past its ends would
        // turn the last samples' jitter into a pan, and into a false reading of movement below.
        let locatedSpan = located[0].time...located[located.count - 1].time
        let smoothed = samples.map { sample in
            smoothedCenter(at: min(max(sample.time, locatedSpan.lowerBound), locatedSpan.upperBound), over: located)
        }
        let centers = isStill(smoothed, size: size)
            ? Array(repeating: Self.unionCenter(of: located), count: samples.count)
            : smoothed

        var keyframes = zip(samples, centers).map { sample, center in
            let kept = sample.joints.map { Self.shifted(center, toContain: $0, size: size) } ?? center
            let framed = Self.slidIntoFrame(kept, size: size)
            return CropKeyframe(time: sample.time, rect: Self.rect(centeredOn: framed, size: size))
        }
        // Outside the located span nothing new is known about the athlete, so the crop holds the
        // end keyframe exactly, containment shift included, rather than stepping back off it.
        if let firstLocated = samples.firstIndex(where: { $0.joints != nil }),
           let lastLocated = samples.lastIndex(where: { $0.joints != nil }) {
            for index in keyframes.indices where index < firstLocated || index > lastLocated {
                let held = keyframes[index < firstLocated ? firstLocated : lastLocated].rect
                keyframes[index] = CropKeyframe(time: keyframes[index].time, rect: held)
            }
        }
        return CropPath(keyframes: keyframes)
    }

    private struct Sample {
        let time: TimeInterval
        /// The located joints' bounding box; `nil` when the frame located none.
        let joints: NormalizedRect?
    }

    private struct LocatedSample {
        let time: TimeInterval
        let center: Point
        let joints: NormalizedRect
        let size: Size
    }

    private struct Point {
        let x: Float
        let y: Float
    }

    private struct Size {
        let width: Float
        let height: Float
    }

    private func locatedSample(from sample: Sample, renderedPixelSize: CGSize) -> LocatedSample? {
        guard let joints = sample.joints else { return nil }
        let corners = [CGPoint(x: CGFloat(joints.minX), y: CGFloat(joints.minY)),
                       CGPoint(x: CGFloat(joints.maxX), y: CGFloat(joints.maxY))]
        guard let rect = rectCalculator.cropRect(
            around: corners, renderedPixelSize: renderedPixelSize, slidIntoFrame: false) else { return nil }
        return LocatedSample(
            time: sample.time,
            center: Point(x: (rect.minX + rect.maxX) / 2, y: (rect.minY + rect.maxY) / 2),
            joints: joints,
            size: Size(width: rect.width, height: rect.height)
        )
    }

    /// The largest per-sample rect, shrunk uniformly to fit inside the frame. Every per-sample
    /// rect has the same pixel aspect ratio, so the widest is also the tallest.
    private func cropSize(fitting located: [LocatedSample]) -> Size {
        let widest = located.map(\.size).max { $0.width < $1.width } ?? Size(width: 1, height: 1)
        let fit = min(1, 1 / widest.width, 1 / widest.height)
        return Size(width: widest.width * fit, height: widest.height * fit)
    }

    /// The athlete center at `time`, from a line fitted through the located centers by weighted
    /// least squares under a Gaussian in time. A weighted line rather than a weighted average,
    /// because an average is one-sided at the window's ends and drags the crop toward the middle
    /// of the motion; a line follows steady motion exactly, ends included.
    private func smoothedCenter(at time: TimeInterval, over located: [LocatedSample]) -> Point {
        let twoVariance = 2 * smoothingSeconds * smoothingSeconds
        var sums = FitSums()
        for sample in located {
            let offset = sample.time - time
            sums.add(offset: offset, weight: exp(-offset * offset / twoVariance), center: sample.center)
        }
        // In the middle of a run of unlocated samples longer than ~77 standard deviations, ~38 from
        // the located samples on either side, every weight underflows to zero and there is
        // nothing to fit.
        guard sums.weight > 0 else {
            let nearest = located.min { abs($0.time - time) < abs($1.time - time) } ?? located[0]
            return nearest.center
        }
        return sums.intercept
    }

    /// Running sums for a weighted least-squares line through centers against time offset.
    private struct FitSums {
        var weight: Double = 0
        var weightedOffset: Double = 0
        var weightedOffsetSquared: Double = 0
        var x: Double = 0
        var y: Double = 0
        var offsetX: Double = 0
        var offsetY: Double = 0

        mutating func add(offset: TimeInterval, weight sampleWeight: Double, center: Point) {
            weight += sampleWeight
            weightedOffset += sampleWeight * offset
            weightedOffsetSquared += sampleWeight * offset * offset
            x += sampleWeight * Double(center.x)
            y += sampleWeight * Double(center.y)
            offsetX += sampleWeight * offset * Double(center.x)
            offsetY += sampleWeight * offset * Double(center.y)
        }

        /// The fitted line's value at offset zero. With every weight on one instant there is no
        /// slope to fit, and the weighted average is the answer.
        var intercept: Point {
            let determinant = weight * weightedOffsetSquared - weightedOffset * weightedOffset
            guard determinant > 1e-12 * weight * weight else {
                return Point(x: Float(x / weight), y: Float(y / weight))
            }
            return Point(
                x: Float((weightedOffsetSquared * x - weightedOffset * offsetX) / determinant),
                y: Float((weightedOffsetSquared * y - weightedOffset * offsetY) / determinant)
            )
        }
    }

    private func isStill(_ centers: [Point], size: Size) -> Bool {
        let xValues = centers.map(\.x), yValues = centers.map(\.y)
        guard let minX = xValues.min(), let maxX = xValues.max(),
              let minY = yValues.min(), let maxY = yValues.max() else {
            return true
        }
        return maxX - minX <= stillnessFraction * size.width && maxY - minY <= stillnessFraction * size.height
    }

    /// Where a still crop centers: on every located joint across the window at once, as the
    /// static crop does.
    private static func unionCenter(of located: [LocatedSample]) -> Point {
        let boxes = located.map(\.joints)
        let minX = boxes.map(\.minX).min() ?? 0, maxX = boxes.map(\.maxX).max() ?? 1
        let minY = boxes.map(\.minY).min() ?? 0, maxY = boxes.map(\.maxY).max() ?? 1
        return Point(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    private static func jointBox(in frame: PoseFrameResult) -> NormalizedRect? {
        let points = CropRectCalculator.locatedPoints(in: [frame])
        guard !points.isEmpty else { return nil }
        let xValues = points.map { Float($0.x) }, yValues = points.map { Float($0.y) }
        return NormalizedRect(
            minX: xValues.min() ?? 0, maxX: xValues.max() ?? 0, minY: yValues.min() ?? 0, maxY: yValues.max() ?? 0)
    }

    private static func shifted(_ center: Point, toContain joints: NormalizedRect, size: Size) -> Point {
        Point(
            x: shifted(center.x, toContain: joints.minX...joints.maxX, length: size.width),
            y: shifted(center.y, toContain: joints.minY...joints.maxY, length: size.height)
        )
    }

    /// The nearest center whose span of `length` covers `range`; a range longer than the span
    /// centers on it, cutting both ends evenly.
    private static func shifted(_ center: Float, toContain range: ClosedRange<Float>, length: Float) -> Float {
        let half = length / 2
        if range.upperBound - range.lowerBound > length { return (range.lowerBound + range.upperBound) / 2 }
        if range.lowerBound < center - half { return range.lowerBound + half }
        if range.upperBound > center + half { return range.upperBound - half }
        return center
    }

    private static func slidIntoFrame(_ center: Point, size: Size) -> Point {
        Point(
            x: min(max(center.x, size.width / 2), 1 - size.width / 2),
            y: min(max(center.y, size.height / 2), 1 - size.height / 2)
        )
    }

    private static func rect(centeredOn center: Point, size: Size) -> NormalizedRect {
        NormalizedRect(
            minX: center.x - size.width / 2,
            maxX: center.x + size.width / 2,
            minY: center.y - size.height / 2,
            maxY: center.y + size.height / 2
        )
    }
}
