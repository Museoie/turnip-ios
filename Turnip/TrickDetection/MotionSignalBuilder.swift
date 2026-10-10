import CoreGraphics
import Foundation

/// How fast the athlete's body moved between two consecutive scored frames.
struct MotionSample: Equatable, Sendable {
    /// Timestamp of the earlier frame of the pair.
    let startTime: TimeInterval
    /// Timestamp of the later frame of the pair.
    let endTime: TimeInterval
    /// Torso lengths per second. `nil` when the pair could not be measured — too few joints
    /// located in both frames, or no torso nearby to scale by. Motion is *unknown* there rather
    /// than zero, and peak detection distinguishes the two.
    let speed: Float?
}

/// Collapses per-frame pose output into the 1D motion signal peak detection runs on
/// (docs/DESIGN.md's pipeline step 4): how fast the whole body moves, in torso lengths per
/// second.
///
/// - Whole body, joint by joint: a trick is as much limbs and rotation as travel, and a kick
///   barely moves the hips. Each joint is compared only with itself, so no fixed offset between
///   two different body points can read as motion.
/// - Torso lengths: the same trick covers far less of the frame when the athlete stands far from
///   the camera, and a passer-by at the lens crosses more of it walking than the athlete does
///   flipping. A body with no torso in view — legs passing the lens — has no scale, and its
///   motion stays unknown.
/// - Pixels, not frame fractions: a portrait frame's fractions are 1.78x longer vertically, which
///   would weigh a jump below a walk.
/// - Per second: the analysis granularity setting changes how finely motion is sampled, not how
///   fast it has to be.
enum MotionSignalBuilder {
    /// Joints located in both frames of a pair before the pair is measured: below this the mean
    /// is a few joints' noise rather than the body's motion.
    static let minimumSharedJoints = 6
    /// Half-width of the window the body scale is the median torso length over. A torso
    /// foreshortens as the athlete bends or tumbles; the median over a few seconds holds the
    /// athlete's size through that.
    static let scaleHalfWindow: TimeInterval = 2
    /// Torso measurements a scale needs inside its window.
    static let minimumScaleMeasurements = 3
    /// Half-width of the median filter — one sample either side at the default 10 samples/sec.
    /// A median rather than a mean: a mean spreads one glitched sample over its neighbours, which
    /// lets a single bad frame pass for sustained motion.
    static let smoothingHalfWindow: TimeInterval = 0.1

    static func buildSignal(from frames: [PoseFrameResult], renderedPixelSize: CGSize) -> [MotionSample] {
        guard frames.count > 1 else { return [] }
        let joints = frames.map { located(in: $0, renderedPixelSize: renderedPixelSize) }
        let scales = bodyScales(torsos: joints.map(torsoLength), times: frames.map(\.timestamp))
        let raw = frames.indices.dropFirst().map { index in
            MotionSample(
                startTime: frames[index - 1].timestamp,
                endTime: frames[index].timestamp,
                speed: speed(
                    from: joints[index - 1], to: joints[index],
                    seconds: frames[index].timestamp - frames[index - 1].timestamp, scale: scales[index]))
        }
        return smoothed(bridgingSingleFrameDropouts(in: raw, frames: frames, joints: joints, scales: scales))
    }

    /// A frame whose pose drops out on its own — every joint lost to blur for one frame mid-trick
    /// — leaves two unknown samples, and two unknowns end a burst. When the frames either side of
    /// it can be measured against each other, both samples take the speed measured straight
    /// across it: the joint-by-joint form of interpolating the missing frame from its neighbours.
    /// Reads only the unbridged samples, so a two-frame hole cannot close by one estimate feeding
    /// the next.
    private static func bridgingSingleFrameDropouts(
        in samples: [MotionSample],
        frames: [PoseFrameResult],
        joints: [[String: Point]],
        scales: [Double?]
    ) -> [MotionSample] {
        var bridged = samples
        for index in frames.indices.dropFirst().dropLast()
        where samples[index - 1].speed == nil && samples[index].speed == nil {
            guard let across = speed(
                from: joints[index - 1], to: joints[index + 1],
                seconds: frames[index + 1].timestamp - frames[index - 1].timestamp, scale: scales[index + 1])
            else { continue }
            for sample in [index - 1, index] {
                bridged[sample] = MotionSample(
                    startTime: samples[sample].startTime, endTime: samples[sample].endTime, speed: across)
            }
        }
        return bridged
    }

    // MARK: - Joints

    private typealias Point = SIMD2<Double>

    /// Left/right joint pairs. Pose models trade the two labels when an athlete turns side-on or
    /// spins, which would read a still athlete's crossed labels as both joints jumping.
    private static let mirroredPairs = ["eye", "ear", "shoulder", "elbow", "wrist", "hip", "knee", "ankle"]
        .map { (left: "left_\($0)", right: "right_\($0)") }

    /// The frame's confident joints, in pixels.
    private static func located(in frame: PoseFrameResult, renderedPixelSize: CGSize) -> [String: Point] {
        // An unknown size still yields a scale-relative signal, just not an isotropic one.
        let width = renderedPixelSize.width > 0 ? Double(renderedPixelSize.width) : 1
        let height = renderedPixelSize.height > 0 ? Double(renderedPixelSize.height) : 1
        var joints: [String: Point] = [:]
        for keypoint in frame.keypoints where keypoint.confidence > PoseKeypoint.confidenceThreshold {
            joints[keypoint.name] = Point(Double(keypoint.x) * width, Double(keypoint.y) * height)
        }
        return joints
    }

    /// Shoulder midpoint to hip midpoint, when all four are located.
    private static func torsoLength(_ joints: [String: Point]) -> Double? {
        guard let leftShoulder = joints["left_shoulder"], let rightShoulder = joints["right_shoulder"],
              let leftHip = joints["left_hip"], let rightHip = joints["right_hip"] else { return nil }
        return distance((leftHip + rightHip) / 2, (leftShoulder + rightShoulder) / 2)
    }

    /// The median torso length within `scaleHalfWindow` of each frame. Frames are in time order.
    private static func bodyScales(torsos: [Double?], times: [TimeInterval]) -> [Double?] {
        var lower = 0
        var upper = 0
        var scales = [Double?]()
        scales.reserveCapacity(times.count)
        for time in times {
            while times[lower] < time - scaleHalfWindow { lower += 1 }
            while upper < times.count, times[upper] <= time + scaleHalfWindow { upper += 1 }
            let measured = torsos[lower..<upper].compactMap { $0 }
            scales.append(measured.count >= minimumScaleMeasurements ? measured.median : nil)
        }
        return scales
    }

    // MARK: - Speed

    /// Mean distance the joints located in both frames moved, in body scales per second.
    private static func speed(
        from earlier: [String: Point],
        to later: [String: Point],
        seconds: TimeInterval,
        scale: Double?
    ) -> Float? {
        guard let scale, scale > 0, seconds > 0 else { return nil }
        var moved: [String: Double] = [:]
        for (name, origin) in earlier {
            if let destination = later[name] { moved[name] = distance(origin, destination) }
        }
        guard moved.count >= minimumSharedJoints else { return nil }
        for pair in mirroredPairs {
            guard let leftMoved = moved[pair.left], let rightMoved = moved[pair.right],
                  let leftFrom = earlier[pair.left], let rightFrom = earlier[pair.right],
                  let leftTo = later[pair.left], let rightTo = later[pair.right] else { continue }
            let crossed = (distance(leftFrom, rightTo) + distance(rightFrom, leftTo)) / 2
            if crossed < (leftMoved + rightMoved) / 2 {
                moved[pair.left] = crossed
                moved[pair.right] = crossed
            }
        }
        return Float(moved.values.reduce(0, +) / Double(moved.count) / scale / seconds)
    }

    private static func distance(_ origin: Point, _ destination: Point) -> Double {
        let offset = destination - origin
        return (offset * offset).sum().squareRoot()
    }

    // MARK: - Smoothing

    /// Median of each known sample and its known neighbours within `smoothingHalfWindow`. A gap
    /// stays a gap: filling it would hand peak detection a speed for a frame pair where the
    /// athlete was never measured.
    private static func smoothed(_ samples: [MotionSample]) -> [MotionSample] {
        let radius = max(1, Int((smoothingHalfWindow / samples.typicalSpacing).rounded()))
        return samples.indices.map { index in
            let sample = samples[index]
            guard sample.speed != nil else { return sample }
            let neighbours = samples[max(0, index - radius)...min(samples.count - 1, index + radius)]
            return MotionSample(
                startTime: sample.startTime,
                endTime: sample.endTime,
                speed: Float(neighbours.compactMap(\.speed).map(Double.init).median))
        }
    }
}

extension Array where Element == MotionSample {
    /// The median time between consecutive frames: the sample rate actually achieved, which the
    /// sampler quantizes to whole-frame strides and the live path can drift from.
    var typicalSpacing: TimeInterval {
        let spacing = map { $0.endTime - $0.startTime }.filter { $0 > 0 }.median
        return spacing > 0 ? spacing : 1 / Double(VideoFrameSampler.targetSamplesPerSecond)
    }
}

extension Array where Element == Double {
    /// The middle value, or the mean of the middle two; 0 when empty.
    var median: Double {
        guard !isEmpty else { return 0 }
        let ordered = sorted()
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2) ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle]
    }
}
