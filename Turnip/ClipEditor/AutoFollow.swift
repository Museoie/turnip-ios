import CoreGraphics
import Foundation

/// Auto follow (`docs/UIUX.md` § "Clip Detail / Editor"): frames the athlete
/// through a window at one turn for the whole clip, as a follow crop of a few keyframes.
///
/// The pipeline's follow path (`CropPathCalculator`) is analysis output, one center per pose
/// sample. Each sample also gets a zoom of its own (`ZoomEnvelope`): the room the athlete needs
/// over a moment, with the static crop's padding, smoothed so the crop changes as the athlete
/// comes closer or moves away rather than with every tuck. Nobody edits forty keyframes with a
/// thumb, so the samples are reduced: keyframes start where the crop starts and stops moving,
/// and one more goes in at the worst sample until the curves through them (`FollowPath`) never
/// show beyond the frame, keep every joint each sample's own crop kept, stray from no sample's
/// center by more than `driftTolerance` of the crop's width, and from no sample's zoom by more
/// than the envelope's `zoomTolerance`. Showing beyond the frame comes first, then a cut limb,
/// since both are worse than a lagging crop. No two keyframes sit closer than
/// `keyframeSpacing`, so a sample that would need one nearer than that goes without: where the
/// curve then cuts a joint that sample's own crop kept, the keyframes either side zoom out until
/// it doesn't (`widenedToHold`), and where it shows beyond the frame, they move in
/// (`heldInsideFrame`).
struct AutoFollow {
    /// How far the curve may stray from a sample's own center, as a fraction of the crop's
    /// width, before a keyframe goes in at that sample.
    static let driftTolerance: CGFloat = 0.1
    /// The least time between two of Auto follow's keyframes: a few diamonds far apart on the
    /// follow lane, each one a moment worth adjusting by hand, rather than a cluster. The two that
    /// start and stop the crop's movement are spread into the holds either side to sit this far
    /// apart, or as far apart as the window's samples reach when it is shorter. Keyframes the
    /// user adds aren't bound by it.
    var keyframeSpacing: TimeInterval = 3
    var pathCalculator = CropPathCalculator()
    /// The tightest crop Auto follow chooses, as the longer side of the source region it shows,
    /// in displayed pixels: export renders a follow clip at its crop rect's size, so a tighter
    /// region is enlarged into it and goes soft. A pinch isn't bound by it.
    var tightestLongerSide: CGFloat = 768
    /// The marker's width over height, which the follow crop's box keeps. Set it through
    /// `shaped(_:)`, which fits the athlete's own rects at the same ratio.
    var aspectRatio = FollowCrop.defaultAspectRatio
    var zoom = ZoomEnvelope()

    /// This fit for a crop of `aspectRatio`: the follow crop's box, and the athlete's own rects
    /// the zoom's room and a still crop's framing are measured from, both take that shape.
    func shaped(_ aspectRatio: CGFloat) -> AutoFollow {
        guard aspectRatio != self.aspectRatio, aspectRatio > 0 else { return self }
        var shaped = self
        let rects = pathCalculator.rectCalculator
        shaped.pathCalculator = CropPathCalculator(
            rectCalculator: CropRectCalculator(
                targetAspectRatio: Float(aspectRatio), paddingFraction: rects.paddingFraction,
                minimumExtentFraction: rects.minimumExtentFraction),
            smoothingSeconds: pathCalculator.smoothingSeconds, stillnessFraction: pathCalculator.stillnessFraction,
            despikeSamples: pathCalculator.despikeSamples)
        shaped.aspectRatio = aspectRatio
        return shaped
    }

    /// Auto follow's crop and whether it moves at all.
    struct Fit: Equatable {
        let crop: FollowCrop
        /// False when the crop holds one framing — the athlete stays put, or a portrait take
        /// leaves the crop no room: "Nothing to follow".
        let moves: Bool
    }

    /// The fit for `frames` (the window's pose samples) on a clip whose crop rect is
    /// `cropRect`, both in the displayed frame's pixels (`videoSize`), turned by
    /// `rotationRadians` throughout. Each sample's zoom comes from the envelope, no wider than
    /// the turned crop can be inside the frame and no tighter than `tightestLongerSide`. `nil`
    /// when no frame located a joint.
    func fit(
        frames: [PoseFrameResult], cropRect: CGRect, videoSize: CGSize, rotationRadians: Double
    ) -> Fit? {
        let sorted = frames.sorted { $0.timestamp < $1.timestamp }
        guard videoSize.width > 0, videoSize.height > 0,
              let path = pathCalculator.cropPath(for: sorted, renderedPixelSize: videoSize)
        else { return nil }
        let marker = ClipEditorViewModel.markerBox(around: cropRect, aspectRatio: aspectRatio)
        guard marker.width > 0, marker.height > 0 else { return nil }
        let ratio = marker.width / marker.height
        let widest = Self.widestFitting(ratio: ratio, rotationRadians: rotationRadians, in: videoSize)
        let tightest = min(tightestLongerSide / max(1, 1 / ratio), widest)
        let samples = samples(
            of: path, frames: sorted, marker: marker, widths: tightest...widest, rotationRadians: rotationRadians,
            videoSize: videoSize)
        let resting = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
        guard let moving = movingRange(of: samples) else {
            return Fit(
                crop: stillCrop(
                    frames: sorted, samples: samples, cropRect: cropRect, videoSize: videoSize,
                    rotationRadians: rotationRadians, widths: tightest...widest, resting: resting),
                moves: false)
        }
        let kept = reduced(samples, moving: moving, marker: marker, rotationRadians: rotationRadians, in: videoSize)
        let widened = Self.widenedToHold(
            kept.map {
                FollowKeyframe(
                    time: samples[$0].time, center: samples[$0].center, scale: samples[$0].scale,
                    rotationRadians: rotationRadians)
            },
            samples: samples, marker: marker,
            widestScale: ClipEditorViewModel.clampedScale(marker.width / widest),
            rotationRadians: rotationRadians, in: videoSize)
        let keyframes = Self.heldInsideFrame(widened, marker: marker, rotationRadians: rotationRadians, in: videoSize)
            .map { FollowKeyframe(time: $0.time, framing: $0.framing, isAuto: true) }
        let restingFraming = FollowFraming(
            center: resting, scale: samples[kept[0]].scale, rotationRadians: rotationRadians)
        return Fit(
            crop: FollowCrop(
                keyframes: keyframes, resting: restingFraming, isAutoFollow: true, aspectRatio: aspectRatio),
            moves: true)
    }

    // swiftlint:disable function_parameter_count
    /// One sample per pose frame: its zoom from the envelope, clamped to `widths`, and the path's
    /// center shifted to hold that frame's de-spiked joints in its own crop and slid inside the
    /// frame.
    private func samples(
        of path: CropPath, frames: [PoseFrameResult], marker: CGRect, widths: ClosedRange<CGFloat>,
        rotationRadians: Double, videoSize: CGSize
    ) -> [Sample] {
        // swiftlint:enable function_parameter_count
        let ratio = marker.width / marker.height
        let athletes = pathCalculator.athletes(for: frames, renderedPixelSize: videoSize)
        let envelope = zoom.widths(
            times: frames.map(\.timestamp),
            needs: athletes.map { $0.map { CGFloat($0.room.maxX - $0.room.minX) * videoSize.width } })
        return zip(path.keyframes, frames).enumerated().map { index, pair in
            let (keyframe, frame) = pair
            let width = min(max(envelope[index], widths.lowerBound), widths.upperBound)
            let scale = ClipEditorViewModel.clampedScale(marker.width / width)
            let box = CGSize(width: marker.width / scale, height: marker.width / scale / ratio)
            let rect = keyframe.rect
            var center = CGPoint(
                x: CGFloat(rect.minX + rect.maxX) / 2 * videoSize.width,
                y: CGFloat(rect.minY + rect.maxY) / 2 * videoSize.height)
            if let joints = athletes[index]?.joints {
                center = Self.shifted(center, toContain: joints.denormalized(in: videoSize), box: box)
            }
            return Sample(
                time: keyframe.time,
                center: Self.slidIntoFrame(center, box: box, rotationRadians: rotationRadians, in: videoSize),
                scale: scale, joints: Self.jointCorners(in: frame, videoSize: videoSize))
        }
    }

    /// What a clip in Follow shows before it has a follow crop of its own: Auto follow's fit
    /// for its window at `rotationRadians`, or the whole frame (`FollowCrop.wholeFrame`) when
    /// nothing in the window was located. Pure, so the Clip List and the editor work out the
    /// same crop for the same clip.
    func defaultCrop(
        poseFrames: [PoseFrameResult], window: TrickWindow, cropRect: CGRect, videoSize: CGSize,
        rotationRadians: Double = 0
    ) -> FollowCrop {
        let framesInWindow = poseFrames.filter {
            $0.timestamp >= window.startTime && $0.timestamp <= window.endTime
        }
        return fit(frames: framesInWindow, cropRect: cropRect, videoSize: videoSize, rotationRadians: rotationRadians)?
            .crop
            ?? FollowCrop.wholeFrame(
                cropRect: cropRect, videoSize: videoSize, rotationRadians: rotationRadians, aspectRatio: aspectRatio)
    }

    private struct Sample {
        let time: TimeInterval
        let center: CGPoint
        let scale: CGFloat
        /// The located joints' bounding-box corners, in displayed pixels; empty when the
        /// sample located none.
        let joints: [CGPoint]
    }

    /// From the last sample of the crop's opening hold to the first of its closing hold: the
    /// stretch where it moves or zooms. `nil` when it never does.
    private func movingRange(of samples: [Sample]) -> ClosedRange<Int>? {
        guard let opening = samples.first, let closing = samples.last else { return nil }
        func holds(_ sample: Sample, _ end: Sample) -> Bool {
            sample.center == end.center && sample.scale == end.scale
        }
        guard let firstMove = samples.firstIndex(where: { !holds($0, opening) }),
              let lastMove = samples.lastIndex(where: { !holds($0, closing) })
        else { return nil }
        return (firstMove - 1)...(lastMove + 1)
    }

    // swiftlint:disable function_parameter_count
    /// One keyframe, mid-window, framing the whole window's joints at once
    /// (`ClipEditorViewModel.autoCropAdjustment`), within the zoom Auto follow allows.
    private func stillCrop(
        frames: [PoseFrameResult], samples: [Sample], cropRect: CGRect, videoSize: CGSize,
        rotationRadians: Double, widths: ClosedRange<CGFloat>, resting: CGPoint
    ) -> FollowCrop {
        // swiftlint:enable function_parameter_count
        let middle = samples[samples.count / 2]
        var center = middle.center
        var scale = middle.scale
        if let fit = ClipEditorViewModel.autoCropAdjustment(
            normalizedKeypoints: CropRectCalculator.locatedPoints(in: frames), cropRect: cropRect,
            videoSize: videoSize, rotationRadians: rotationRadians, calculator: pathCalculator.rectCalculator) {
            let marker = ClipEditorViewModel.markerBox(around: cropRect, aspectRatio: aspectRatio)
            let width = min(max(marker.width / fit.scale, widths.lowerBound), widths.upperBound)
            scale = ClipEditorViewModel.clampedScale(marker.width / width)
            let box = CGSize(width: marker.width / scale, height: marker.height / scale)
            center = Self.slidIntoFrame(
                FramingConversion.followCenter(of: fit, cropCenter: CGPoint(x: cropRect.midX, y: cropRect.midY)),
                box: box, rotationRadians: rotationRadians, in: videoSize)
        }
        return FollowCrop(
            keyframes: [FollowKeyframe(
                time: middle.time,
                framing: FollowFraming(center: center, scale: scale, rotationRadians: rotationRadians),
                isAuto: true)],
            resting: FollowFraming(center: resting, scale: scale, rotationRadians: rotationRadians),
            isAutoFollow: true,
            aspectRatio: aspectRatio)
    }

    private func reduced(
        _ samples: [Sample], moving: ClosedRange<Int>, marker: CGRect, rotationRadians: Double, in frame: CGSize
    ) -> [Int] {
        func box(_ scale: CGFloat) -> CGSize {
            CGSize(width: marker.width / scale, height: marker.height / scale)
        }
        let span = spread(moving, in: samples)
        var kept = [span.lowerBound, span.upperBound]
        func isSpaced(_ index: Int) -> Bool {
            kept.allSatisfy { abs(samples[$0].time - samples[index].time) >= keyframeSpacing - 1e-6 }
        }
        let held = samples.map {
            Self.overflow(
                of: $0.joints, around: $0.center, box: box($0.scale), rotationRadians: rotationRadians) <= 1e-6
        }
        let zoomTolerance = log(1 + zoom.zoomTolerance)
        while true {
            let path = FollowPath(
                keyframes: kept.map {
                    FollowKeyframe(
                        time: samples[$0].time, center: samples[$0].center, scale: samples[$0].scale,
                        rotationRadians: rotationRadians)
                },
                resting: FollowFraming(center: samples[span.lowerBound].center, scale: 1, rotationRadians: 0))
            var worst: [(index: Int, amount: CGFloat)?] = [nil, nil, nil, nil]
            func note(_ rank: Int, _ index: Int, _ amount: CGFloat) {
                if amount > worst[rank]?.amount ?? 0 { worst[rank] = (index, amount) }
            }
            for index in span where isSpaced(index) {
                let sample = samples[index]
                let framing = path.framing(at: sample.time)
                let size = box(framing.scale)
                let outside = Self.outsideFrame(
                    center: framing.center, box: size, rotationRadians: rotationRadians, in: frame)
                if outside > 0.5 { note(0, index, outside) }
                if held[index] {
                    let cut = Self.overflow(
                        of: sample.joints, around: framing.center, box: size, rotationRadians: rotationRadians)
                    if cut > 1e-6 { note(1, index, cut) }
                }
                let drift = hypot(framing.center.x - sample.center.x, framing.center.y - sample.center.y) / size.width
                if drift > Self.driftTolerance { note(2, index, drift) }
                let stray = abs(log(framing.scale / sample.scale))
                if stray > zoomTolerance { note(3, index, stray) }
            }
            guard let next = worst.compactMap({ $0 }).first else { return kept }
            kept.append(next.index)
            kept.sort()
        }
    }

    /// `moving`, spread into the holds either side until its two ends are `keyframeSpacing` apart,
    /// evenly where the samples allow; every sample when they span less than that. The samples
    /// outside `moving` hold its ends' framings, so the keyframes there frame the same and the
    /// crop only takes longer over the move.
    private func spread(_ moving: ClosedRange<Int>, in samples: [Sample]) -> ClosedRange<Int> {
        let start = samples[moving.lowerBound].time, end = samples[moving.upperBound].time
        let shortfall = keyframeSpacing - (end - start)
        guard shortfall > 0 else { return moving }
        let first = samples[0].time, last = samples[samples.count - 1].time
        guard last - first > keyframeSpacing else { return 0...(samples.count - 1) }
        var lower = start - shortfall / 2, upper = end + shortfall / 2
        if lower < first {
            upper += first - lower
            lower = first
        }
        if upper > last {
            lower -= upper - last
            upper = last
        }
        let lowerIndex = samples.lastIndex { $0.time <= lower + 1e-9 } ?? 0
        let upperIndex = samples.firstIndex { $0.time >= upper - 1e-9 } ?? samples.count - 1
        return min(lowerIndex, moving.lowerBound)...max(upperIndex, moving.upperBound)
    }

    // swiftlint:disable function_parameter_count
    /// `keyframes` zoomed out, a stretch at a time, until the curves through them keep every joint
    /// each sample's own crop kept. With keyframes `keyframeSpacing` apart the curve between two
    /// can't bend to follow an athlete who moves away and back, so where a sample's joints fall
    /// outside the curve's crop, the keyframes either side widen by as much as that crop would
    /// have to, and slide back inside the frame. Two keyframes that widen together widen every
    /// crop between them by that much, exactly when they are the only two and close to it
    /// otherwise, so the check repeats until nothing is cut, or the keyframes are as wide as the
    /// frame allows (`widestScale`, the smallest zoom) and the athlete outruns even that.
    private static func widenedToHold(
        _ keyframes: [FollowKeyframe], samples: [Sample], marker: CGRect, widestScale: CGFloat,
        rotationRadians: Double, in frame: CGSize
    ) -> [FollowKeyframe] {
        // swiftlint:enable function_parameter_count
        func box(_ scale: CGFloat) -> CGSize {
            CGSize(width: marker.width / scale, height: marker.height / scale)
        }
        let held = samples.filter { sample in
            let own = overflow(
                of: sample.joints, around: sample.center, box: box(sample.scale), rotationRadians: rotationRadians)
            return !sample.joints.isEmpty && own <= 1e-6
        }
        var keyframes = keyframes
        for _ in 0..<8 {
            let path = FollowPath(keyframes: keyframes, resting: keyframes[0].framing)
            var growth = Array(repeating: CGFloat(1), count: keyframes.count)
            for sample in held {
                let framing = path.framing(at: sample.time)
                let needed = reach(
                    of: sample.joints, around: framing.center, box: box(framing.scale),
                    rotationRadians: rotationRadians)
                guard needed > 1 + 1e-6 else { continue }
                let after = keyframes.firstIndex { $0.time >= sample.time } ?? keyframes.count - 1
                for index in Set([max(after - 1, 0), after]) {
                    growth[index] = max(growth[index], needed)
                }
            }
            var widened = false
            for index in keyframes.indices where growth[index] > 1 + 1e-6 {
                let scale = max(keyframes[index].scale / growth[index], widestScale)
                guard scale < keyframes[index].scale - 1e-9 else { continue }
                widened = true
                keyframes[index].scale = scale
                keyframes[index].center = slidIntoFrame(
                    keyframes[index].center, box: box(scale), rotationRadians: rotationRadians, in: frame)
            }
            guard widened else { break }
        }
        return keyframes
    }

    /// How many times larger a crop of `box` centered on `center` and turned by the rotation
    /// would have to be, about the same center, to hold every one of `joints`; at most 1 when it
    /// already does.
    private static func reach(
        of joints: [CGPoint], around center: CGPoint, box: CGSize, rotationRadians: Double
    ) -> CGFloat {
        let turn = CGAffineTransform(rotationAngle: rotationRadians)
        var reach: CGFloat = 0
        for joint in joints {
            let onScreen = CGPoint(x: joint.x - center.x, y: joint.y - center.y).applying(turn)
            reach = max(reach, abs(onScreen.x) / (box.width / 2), abs(onScreen.y) / (box.height / 2))
        }
        return reach
    }

    /// `keyframes` with the curves through them kept from showing beyond the frame where too few
    /// keyframes are allowed to hold them there: each center slid inside the frame for the widest
    /// crop among its keyframe and the two beside it. Between two keyframes the center and the
    /// zoom each stay between their values at the two (`MonotoneCubic` never overshoots), and a
    /// wider crop only narrows where its center can sit, so a center that holds the wider of the
    /// two crops inside the frame holds every crop between them. Unchanged where the curves stay
    /// inside already.
    private static func heldInsideFrame(
        _ keyframes: [FollowKeyframe], marker: CGRect, rotationRadians: Double, in frame: CGSize
    ) -> [FollowKeyframe] {
        func box(_ scale: CGFloat) -> CGSize {
            CGSize(width: marker.width / scale, height: marker.height / scale)
        }
        guard let first = keyframes.first, let last = keyframes.last else { return keyframes }
        let path = FollowPath(keyframes: keyframes, resting: first.framing)
        let showsBeyond = stride(from: first.time, through: last.time, by: 1.0 / 60).contains { time in
            let framing = path.framing(at: time)
            return outsideFrame(
                center: framing.center, box: box(framing.scale), rotationRadians: rotationRadians, in: frame) > 0.5
        }
        guard showsBeyond else { return keyframes }
        return keyframes.indices.map { index in
            let widest = keyframes[max(index - 1, 0)...min(index + 1, keyframes.count - 1)].map(\.scale).min()
            var keyframe = keyframes[index]
            keyframe.center = slidIntoFrame(
                keyframe.center, box: box(widest ?? keyframe.scale), rotationRadians: rotationRadians, in: frame)
            return keyframe
        }
    }

    /// How far, in displayed pixels, a crop of `box` centered on `center` and turned by the
    /// rotation reaches past the frame's edge at its farthest corner; 0 when it is inside.
    private static func outsideFrame(
        center: CGPoint, box: CGSize, rotationRadians: Double, in frame: CGSize
    ) -> CGFloat {
        let cosine = abs(cos(rotationRadians)), sine = abs(sin(rotationRadians))
        let halfAcross = (cosine * box.width + sine * box.height) / 2
        let halfDown = (sine * box.width + cosine * box.height) / 2
        return max(
            0, halfAcross - center.x, center.x + halfAcross - frame.width,
            halfDown - center.y, center.y + halfDown - frame.height)
    }

    /// How far the farthest of `joints` lies outside a crop of `box` centered on `center` and
    /// turned by the rotation, as a fraction of the box's width; 0 when all are inside.
    private static func overflow(
        of joints: [CGPoint], around center: CGPoint, box: CGSize, rotationRadians: Double
    ) -> CGFloat {
        let turn = CGAffineTransform(rotationAngle: rotationRadians)
        var worst: CGFloat = 0
        for joint in joints {
            let onScreen = CGPoint(x: joint.x - center.x, y: joint.y - center.y).applying(turn)
            worst = max(worst, abs(onScreen.x) - box.width / 2, abs(onScreen.y) - box.height / 2)
        }
        return worst / box.width
    }

    /// The nearest center whose unturned `box` holds `joints` on each axis, as the path's own
    /// containment shift does at the path's size; an axis the joints overfill centers on them.
    private static func shifted(_ center: CGPoint, toContain joints: CGRect, box: CGSize) -> CGPoint {
        func shifted(_ value: CGFloat, lower: CGFloat, upper: CGFloat, length: CGFloat) -> CGFloat {
            if upper - lower > length { return (lower + upper) / 2 }
            return min(max(value, upper - length / 2), lower + length / 2)
        }
        return CGPoint(
            x: shifted(center.x, lower: joints.minX, upper: joints.maxX, length: box.width),
            y: shifted(center.y, lower: joints.minY, upper: joints.maxY, length: box.height))
    }

    /// The widest box of `ratio` whose turned footprint fits inside the frame.
    static func widestFitting(ratio: CGFloat, rotationRadians: Double, in frame: CGSize) -> CGFloat {
        let cosine = abs(cos(rotationRadians)), sine = abs(sin(rotationRadians))
        return min(frame.width / (cosine + sine / ratio), frame.height / (sine + cosine / ratio))
    }

    /// `center` moved the least distance that keeps the crop's turned footprint inside the
    /// frame, so the crop shows video in every part of it; centered on an axis the footprint
    /// can't fit.
    static func slidIntoFrame(
        _ center: CGPoint, box: CGSize, rotationRadians: Double, in frame: CGSize
    ) -> CGPoint {
        let cosine = abs(cos(rotationRadians)), sine = abs(sin(rotationRadians))
        let halfAcross = (cosine * box.width + sine * box.height) / 2
        let halfDown = (sine * box.width + cosine * box.height) / 2
        func clamp(_ value: CGFloat, half: CGFloat, length: CGFloat) -> CGFloat {
            half * 2 >= length ? length / 2 : min(max(value, half), length - half)
        }
        return CGPoint(
            x: clamp(center.x, half: halfAcross, length: frame.width),
            y: clamp(center.y, half: halfDown, length: frame.height))
    }

    private static func jointCorners(in frame: PoseFrameResult, videoSize: CGSize) -> [CGPoint] {
        let points = CropRectCalculator.locatedPoints(in: [frame]).map {
            CGPoint(x: min(max($0.x, 0), 1) * videoSize.width, y: min(max($0.y, 0), 1) * videoSize.height)
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
        else { return [] }
        return [
            CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
            CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)
        ]
    }
}

/// Converts a framing from `CropAdjustment`'s terms — the video turned and zoomed about the
/// clip's crop center and then offset on screen, the terms `ClipEditorViewModel.autoCropAdjustment`
/// fits in — into a follow crop's, a source point moved onto the marker's center and turned and
/// zoomed about it (`docs/DESIGN.md` step 6). The same picture is one source point at the
/// marker's center at the same zoom and turn.
enum FramingConversion {
    /// The source point an adjustment puts at the marker's center, in displayed pixels:
    /// a point `p` lands at `R·s·(p − cropCenter) + offset` from it, so the center shows
    /// `cropCenter − R⁻¹·offset / s`.
    static func followCenter(of adjustment: CropAdjustment, cropCenter: CGPoint) -> CGPoint {
        guard adjustment.scale > 0 else { return cropCenter }
        let unturned = CGPoint(x: adjustment.offset.width, y: adjustment.offset.height)
            .applying(CGAffineTransform(rotationAngle: -adjustment.rotationRadians))
        return CGPoint(
            x: cropCenter.x - unturned.x / adjustment.scale,
            y: cropCenter.y - unturned.y / adjustment.scale)
    }
}

extension FollowCrop {
    /// Reset follow's crop: the whole source frame centered in the marker, at
    /// `rotationRadians`, with no keyframes, so it holds still.
    static func wholeFrame(
        cropRect: CGRect, videoSize: CGSize, rotationRadians: Double, aspectRatio: CGFloat
    ) -> FollowCrop {
        let marker = ClipEditorViewModel.markerBox(around: cropRect, aspectRatio: aspectRatio)
        let frame = ClipEditorViewModel.markerBox(
            around: CGRect(origin: .zero, size: videoSize), aspectRatio: aspectRatio)
        let scale = frame.width > 0 ? ClipEditorViewModel.clampedScale(marker.width / frame.width) : 1
        return FollowCrop(
            keyframes: [],
            resting: FollowFraming(
                center: CGPoint(x: videoSize.width / 2, y: videoSize.height / 2), scale: scale,
                rotationRadians: rotationRadians),
            isAutoFollow: false,
            aspectRatio: aspectRatio)
    }
}
