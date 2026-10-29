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
/// since both are worse than a lagging crop.
struct AutoFollow {
    /// How far the curve may stray from a sample's own center, as a fraction of the crop's
    /// width, before a keyframe goes in at that sample.
    static let driftTolerance: CGFloat = 0.1
    var pathCalculator = CropPathCalculator()
    /// The tightest crop Auto follow chooses, as the longer side of the source region it shows,
    /// in displayed pixels: export renders a follow clip at its crop rect's size, so a tighter
    /// region is enlarged into it and goes soft. A pinch isn't bound by it.
    var tightestLongerSide: CGFloat = 768
    /// The marker's width over height, which the follow crop's box keeps.
    var aspectRatio = CGFloat(CropRectCalculator().targetAspectRatio)
    var zoom = ZoomEnvelope()

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
        let keyframes = kept.map {
            FollowKeyframe(
                time: samples[$0].time,
                framing: FollowFraming(
                    center: samples[$0].center, scale: samples[$0].scale, rotationRadians: rotationRadians),
                isAuto: true)
        }
        let restingFraming = FollowFraming(
            center: resting, scale: samples[kept[0]].scale, rotationRadians: rotationRadians)
        return Fit(crop: FollowCrop(keyframes: keyframes, resting: restingFraming, isAutoFollow: true), moves: true)
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
            isAutoFollow: true)
    }

    private func reduced(
        _ samples: [Sample], moving: ClosedRange<Int>, marker: CGRect, rotationRadians: Double, in frame: CGSize
    ) -> [Int] {
        func box(_ scale: CGFloat) -> CGSize {
            CGSize(width: marker.width / scale, height: marker.height / scale)
        }
        var kept = [moving.lowerBound, moving.upperBound]
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
                resting: FollowFraming(center: samples[moving.lowerBound].center, scale: 1, rotationRadians: 0))
            var worst: [(index: Int, amount: CGFloat)?] = [nil, nil, nil, nil]
            func note(_ rank: Int, _ index: Int, _ amount: CGFloat) {
                if amount > worst[rank]?.amount ?? 0 { worst[rank] = (index, amount) }
            }
            for index in moving where !kept.contains(index) {
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
            isAutoFollow: false)
    }
}
