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

    /// The motion signal over `frames`, built by streaming them through
    /// `StreamingMotionSignal` one at a time: the batch form is the streaming form fed
    /// the whole array, so the two can never drift — the detector the pipeline streams
    /// and the one the camera's hand-off calls over arrays read the same signal.
    static func buildSignal(from frames: [PoseFrameResult], renderedPixelSize: CGSize) -> [MotionSample] {
        var stream = StreamingMotionSignal(renderedPixelSize: renderedPixelSize)
        for frame in frames {
            stream.consume(frame)
        }
        return stream.finish()
    }

    // MARK: - Joints

    /// Joints are `SIMD2<Double>` pixels; the alias is internal because `located`,
    /// `torsoLength`, and `speed` are called from `StreamingMotionSignal` and expose
    /// it in their signatures (a private alias there is a compile error).
    typealias Point = SIMD2<Double>

    /// Left/right joint pairs. Pose models trade the two labels when an athlete turns side-on or
    /// spins, which would read a still athlete's crossed labels as both joints jumping.
    private static let mirroredPairs = ["eye", "ear", "shoulder", "elbow", "wrist", "hip", "knee", "ankle"]
        .map { (left: "left_\($0)", right: "right_\($0)") }

    /// The frame's confident joints, in pixels.
    static func located(in frame: PoseFrameResult, renderedPixelSize: CGSize) -> [String: Point] {
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
    static func torsoLength(_ joints: [String: Point]) -> Double? {
        guard let leftShoulder = joints["left_shoulder"], let rightShoulder = joints["right_shoulder"],
              let leftHip = joints["left_hip"], let rightHip = joints["right_hip"] else { return nil }
        return distance((leftHip + rightHip) / 2, (leftShoulder + rightShoulder) / 2)
    }

    /// The median torso length within `scaleHalfWindow` of each frame. Frames are in time order.
    static func bodyScales(torsos: [Double?], times: [TimeInterval]) -> [Double?] {
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
    static func speed(
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
    static func smoothed(_ samples: [MotionSample]) -> [MotionSample] {
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

/// Builds the motion signal one frame at a time, holding only the frames inside the
/// lookahead the scale and bridging steps need: a frame's scale needs torsos up to
/// `scaleHalfWindow` ahead of it, and a single-frame dropout is bridged from the frames
/// either side of it, so a frame leaves once its scale is final and no later step can
/// still read it. A long take's memory is then a few seconds of frames plus the signal
/// itself — one small sample per frame pair — not the take.
///
/// The signal is exactly `MotionSignalBuilder.buildSignal`'s: the batch form is this
/// streamer fed the whole array, and the existing signal tests pin the values. The
/// pieces that need the whole take — the smoothing radius from the median spacing —
/// run over the finished samples in `finish()`, never over the frames.
struct StreamingMotionSignal: Sendable {
    private let renderedPixelSize: CGSize

    /// One buffered frame: what the scale step still needs of it. The joints leave with
    /// the entry; `recent` below carries the joints the sample and bridging steps still
    /// need after that, so a gap of any length between two frames cannot strand a sample.
    private struct Buffered {
        let timestamp: TimeInterval
        let joints: [String: SIMD2<Double>]
        let torso: Double?
        var scale: Double?
        var scaleFinalized = false
    }

    private var buffered: [Buffered] = []
    /// Overall frame index of `buffered[0]`; entries leave from the front.
    private var firstBufferedIndex = 0
    /// Offset into `buffered` of the first entry whose scale is not final.
    private var firstUnfinalized = 0

    /// Emitted samples in pair order, with bridging applied as scales finalize.
    private var samples: [MotionSample] = []
    /// The pre-bridge speed of each emitted sample, in the same order: bridging
    /// decides from these, never from an already-bridged value, so a bridge cannot feed
    /// the next one — the same rule the batch form's separate pass enforces.
    private var rawSpeeds: [Float?] = []
    /// The joints and times of the last two finalized frames, oldest first: the pair
    /// a sample is emitted for, and the bridge source one frame further back.
    private var recent: [(joints: [String: SIMD2<Double>], timestamp: TimeInterval)] = []

    init(renderedPixelSize: CGSize) {
        self.renderedPixelSize = renderedPixelSize
    }

    /// Feeds one frame, in time order.
    mutating func consume(_ frame: PoseFrameResult) {
        let joints = MotionSignalBuilder.located(in: frame, renderedPixelSize: renderedPixelSize)
        buffered.append(Buffered(
            timestamp: frame.timestamp,
            joints: joints,
            torso: MotionSignalBuilder.torsoLength(joints)))
        finalizeScales()
        dropStaleEntries()
    }

    /// The finished signal: the remaining scales finalize against the frames that
    /// arrived — no more are coming — then the remaining samples and bridges, then the
    /// smoothing over the completed samples, exactly as the batch form runs it.
    mutating func finish() -> [MotionSample] {
        while firstUnfinalized < buffered.count {
            finalizeScale(at: firstUnfinalized)
            firstUnfinalized += 1
        }
        return MotionSignalBuilder.smoothed(samples)
    }

    /// Finalizes the scales whose windows are complete: a scale needs torsos up to
    /// `scaleHalfWindow` past its frame, so it is final once a frame arrives past that
    /// bound. Strictly past: a frame at exactly the bound still belongs in the window.
    private mutating func finalizeScales() {
        guard let newest = buffered.last?.timestamp else { return }
        while firstUnfinalized < buffered.count,
              newest > buffered[firstUnfinalized].timestamp + MotionSignalBuilder.scaleHalfWindow {
            finalizeScale(at: firstUnfinalized)
            firstUnfinalized += 1
        }
    }

    /// Finalizes one entry's scale against the buffered torsos — the window's members
    /// are all here by the finalization condition — then emits its sample and decides
    /// the bridge its scale unlocks, in the same order the batch form does.
    private mutating func finalizeScale(at offset: Int) {
        let scales = MotionSignalBuilder.bodyScales(
            torsos: buffered.map(\.torso), times: buffered.map(\.timestamp))
        buffered[offset].scale = scales[offset]
        buffered[offset].scaleFinalized = true
        let entry = buffered[offset]
        let index = firstBufferedIndex + offset
        emitSample(for: index, entry: entry)
        decideBridge(for: index, entry: entry)
        recent.append((joints: entry.joints, timestamp: entry.timestamp))
        if recent.count > 2 {
            recent.removeFirst()
        }
    }

    /// The sample pairing the previous frame with this one, emitted when this frame's
    /// scale finalizes. The previous frame's joints ride in `recent`, so the sample
    /// does not depend on the buffer still holding it.
    private mutating func emitSample(for index: Int, entry: Buffered) {
        guard index >= 1, let previous = recent.last else { return }
        let speed = MotionSignalBuilder.speed(
            from: previous.joints, to: entry.joints,
            seconds: entry.timestamp - previous.timestamp, scale: entry.scale)
        samples.append(MotionSample(
            startTime: previous.timestamp, endTime: entry.timestamp, speed: speed))
        rawSpeeds.append(speed)
    }

    /// The bridge the just-finalized scale unlocks: the frame before this one dropped
    /// out on its own, so the two samples around it are unknown and the frames either
    /// side can be measured straight across it. Decided from the raw speeds, in
    /// increasing frame order, so overlapping bridges overwrite in the same order the
    /// batch form's loop does.
    private mutating func decideBridge(for index: Int, entry: Buffered) {
        // The dropped frame is `index - 1`: its scale is the one just finalized, and the
        // samples around it are the two most recently emitted.
        guard index >= 2,
              rawSpeeds[index - 2] == nil, rawSpeeds[index - 1] == nil,
              let acrossBase = recent.first
        else { return }
        guard let across = MotionSignalBuilder.speed(
            from: acrossBase.joints, to: entry.joints,
            seconds: entry.timestamp - acrossBase.timestamp, scale: entry.scale)
        else { return }
        for sample in [index - 2, index - 1] {
            samples[sample] = MotionSample(
                startTime: samples[sample].startTime, endTime: samples[sample].endTime, speed: across)
        }
    }

    /// Drops entries no later step can still read: finalized, and older than the oldest
    /// unfinalized frame's scale window (or the newest frame's, when everything is
    /// final). Their torsos cannot enter any future window, and their joints were
    /// consumed at finalization.
    private mutating func dropStaleEntries() {
        let threshold: TimeInterval
        if firstUnfinalized < buffered.count {
            threshold = buffered[firstUnfinalized].timestamp - MotionSignalBuilder.scaleHalfWindow
        } else if let newest = buffered.last?.timestamp {
            threshold = newest - MotionSignalBuilder.scaleHalfWindow
        } else {
            return
        }
        var dropped = 0
        while dropped < buffered.count,
              buffered[dropped].scaleFinalized,
              buffered[dropped].timestamp < threshold {
            dropped += 1
        }
        guard dropped > 0 else { return }
        buffered.removeFirst(dropped)
        firstBufferedIndex += dropped
        firstUnfinalized -= dropped
    }
}
