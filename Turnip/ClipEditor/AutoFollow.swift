import CoreGraphics
import Foundation

/// Auto follow (`docs/UIUX.md` § "Two framing modes, Still and Follow"): frames the athlete
/// through a window at the current rotation, as a follow crop of a few keyframes.
///
/// The pipeline's follow path (`CropPathCalculator`) is analysis output, one center per pose
/// sample. Nobody edits forty keyframes with a thumb, so the path is reduced: keyframes start
/// where the path starts and stops moving, and one more goes in at the worst sample until the
/// curve through them (`FollowPath`) keeps every joint the path itself kept inside the crop,
/// and strays from no sample's center by more than `driftTolerance` of the crop's width.
/// Containment comes first, since a cut limb is worse than a lagging crop.
struct AutoFollow {
    /// How far the curve may stray from a sample's own center, as a fraction of the crop's
    /// width, before a keyframe goes in at that sample.
    static let driftTolerance: CGFloat = 0.1

    var pathCalculator = CropPathCalculator()
    /// The marker's width over height, which the follow crop's box keeps.
    var aspectRatio = CGFloat(CropRectCalculator().targetAspectRatio)

    /// Auto follow's crop and whether it moves at all.
    struct Fit: Equatable {
        let crop: FollowCrop
        /// False when the crop holds one framing — the athlete stays put, or a portrait take
        /// leaves the crop no room at the fitted zoom: "Nothing to follow".
        let moves: Bool
    }

    /// The fit for `frames` (the window's pose samples) on a clip whose crop rect is
    /// `cropRect`, both in the displayed frame's pixels (`videoSize`), turned by
    /// `rotationRadians`. With a `scale` the zoom stays and only the positions are refitted —
    /// a trim re-tracking an untouched Auto follow; without one the zoom is the path's, the
    /// widest the athlete needs at any one moment, shrunk until the turned crop fits the
    /// frame. `nil` when no frame located a joint.
    func fit(
        frames: [PoseFrameResult], cropRect: CGRect, videoSize: CGSize, rotationRadians: Double,
        scale fixedScale: CGFloat? = nil
    ) -> Fit? {
        let sorted = frames.sorted { $0.timestamp < $1.timestamp }
        guard videoSize.width > 0, videoSize.height > 0,
              let path = pathCalculator.cropPath(for: sorted, renderedPixelSize: videoSize),
              let first = path.keyframes.first
        else { return nil }
        let marker = ClipEditorViewModel.markerBox(around: cropRect, aspectRatio: aspectRatio)
        guard marker.width > 0, marker.height > 0 else { return nil }
        let ratio = marker.width / marker.height
        let pathWidth = CGFloat(first.rect.maxX - first.rect.minX) * videoSize.width
        let widest = Self.widestFitting(ratio: ratio, rotationRadians: rotationRadians, in: videoSize)
        let scale = ClipEditorViewModel.clampedScale(fixedScale ?? marker.width / min(pathWidth, widest))
        let box = CGSize(width: marker.width / scale, height: marker.width / scale / ratio)

        let samples = zip(path.keyframes, sorted).map { keyframe, frame in
            let rect = keyframe.rect
            let center = CGPoint(
                x: CGFloat(rect.minX + rect.maxX) / 2 * videoSize.width,
                y: CGFloat(rect.minY + rect.maxY) / 2 * videoSize.height)
            let framed = Self.slidIntoFrame(center, box: box, rotationRadians: rotationRadians, in: videoSize)
            return Sample(
                time: keyframe.time, center: framed,
                joints: Self.jointCorners(in: frame, videoSize: videoSize))
        }
        let resting = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
        guard let moving = movingRange(of: samples) else {
            return Fit(
                crop: stillCrop(
                    frames: sorted, samples: samples, cropRect: cropRect, videoSize: videoSize,
                    rotationRadians: rotationRadians, fixedScale: fixedScale, scale: scale, resting: resting),
                moves: false)
        }
        let kept = reduced(samples, moving: moving, box: box, rotationRadians: rotationRadians)
        let keyframes = kept.map {
            FollowKeyframe(
                time: samples[$0].time,
                framing: FollowFraming(center: samples[$0].center, scale: scale, rotationRadians: rotationRadians),
                isAuto: true)
        }
        return Fit(
            crop: FollowCrop(
                keyframes: keyframes,
                resting: FollowFraming(center: resting, scale: scale, rotationRadians: rotationRadians),
                isAutoFollow: true),
            moves: true)
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
        /// The located joints' bounding-box corners, in displayed pixels; empty when the
        /// sample located none.
        let joints: [CGPoint]
    }

    /// From the last sample of the path's opening hold to the first of its closing hold: the
    /// stretch where it moves. `nil` when it never does.
    private func movingRange(of samples: [Sample]) -> ClosedRange<Int>? {
        guard let opening = samples.first?.center, let closing = samples.last?.center else { return nil }
        guard let firstMove = samples.firstIndex(where: { $0.center != opening }),
              let lastMove = samples.lastIndex(where: { $0.center != closing })
        else { return nil }
        return (firstMove - 1)...(lastMove + 1)
    }

    // swiftlint:disable function_parameter_count
    /// One keyframe, mid-window. With the zoom free, it is Auto crop's framing for the whole
    /// window (every joint at once); a re-track at a kept zoom holds the path's own center.
    private func stillCrop(
        frames: [PoseFrameResult], samples: [Sample], cropRect: CGRect, videoSize: CGSize,
        rotationRadians: Double, fixedScale: CGFloat?, scale: CGFloat, resting: CGPoint
    ) -> FollowCrop {
        // swiftlint:enable function_parameter_count
        let time = samples[samples.count / 2].time
        var center = samples[samples.count / 2].center
        var stillScale = scale
        if fixedScale == nil,
           let fit = ClipEditorViewModel.autoCropAdjustment(
               normalizedKeypoints: CropRectCalculator.locatedPoints(in: frames), cropRect: cropRect,
               videoSize: videoSize, rotationRadians: rotationRadians,
               calculator: pathCalculator.rectCalculator) {
            let still = FramingConversion.followCenter(
                of: fit, cropCenter: CGPoint(x: cropRect.midX, y: cropRect.midY))
            center = still
            stillScale = fit.scale
        }
        return FollowCrop(
            keyframes: [FollowKeyframe(
                time: time,
                framing: FollowFraming(center: center, scale: stillScale, rotationRadians: rotationRadians),
                isAuto: true)],
            resting: FollowFraming(center: resting, scale: stillScale, rotationRadians: rotationRadians),
            isAutoFollow: true)
    }

    private func reduced(
        _ samples: [Sample], moving: ClosedRange<Int>, box: CGSize, rotationRadians: Double
    ) -> [Int] {
        var kept = [moving.lowerBound, moving.upperBound]
        let held = samples.map {
            Self.overflow(of: $0.joints, around: $0.center, box: box, rotationRadians: rotationRadians) <= 1e-6
        }
        while true {
            let path = FollowPath(
                keyframes: kept.map { FollowKeyframe(time: samples[$0].time, center: samples[$0].center) },
                resting: FollowFraming(center: samples[moving.lowerBound].center, scale: 1, rotationRadians: 0))
            var worstCut: (index: Int, amount: CGFloat)?
            var worstDrift: (index: Int, amount: CGFloat)?
            for index in moving where !kept.contains(index) {
                let center = path.center(at: samples[index].time)
                if held[index] {
                    let cut = Self.overflow(
                        of: samples[index].joints, around: center, box: box, rotationRadians: rotationRadians)
                    if cut > 1e-6, cut > worstCut?.amount ?? 0 { worstCut = (index, cut) }
                }
                let drift = hypot(center.x - samples[index].center.x, center.y - samples[index].center.y) / box.width
                if drift > Self.driftTolerance, drift > worstDrift?.amount ?? 0 { worstDrift = (index, drift) }
            }
            guard let worst = worstCut ?? worstDrift else { return kept }
            kept.append(worst.index)
            kept.sort()
        }
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

/// Converts a framing between the two modes' terms. Still mode turns and zooms the video
/// about the clip's crop center and then offsets it on screen; Follow mode moves a source
/// point onto the marker's center and turns and zooms about it (`docs/DESIGN.md` step 6). The
/// same picture is one source point at the marker's center at the same zoom and turn.
enum FramingConversion {
    /// The source point a still adjustment puts at the marker's center, in displayed pixels:
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

    /// The on-screen offset, in displayed pixels, that a still adjustment of `scale` and
    /// `rotationRadians` needs to put `center` at the marker's center — `followCenter`'s
    /// inverse.
    static func stillOffset(
        centering center: CGPoint, cropCenter: CGPoint, scale: CGFloat, rotationRadians: Double
    ) -> CGSize {
        let turned = CGPoint(x: (cropCenter.x - center.x) * scale, y: (cropCenter.y - center.y) * scale)
            .applying(CGAffineTransform(rotationAngle: rotationRadians))
        return CGSize(width: turned.x, height: turned.y)
    }
}

extension FollowCrop {
    /// Reset follow's crop: the whole source frame centered in the marker, at
    /// `rotationRadians`, with no keyframes, so it holds still — the follow counterpart of
    /// Reset crop (`ClipEditorViewModel.fullFrameAdjustment`).
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
