import CoreGraphics
import Foundation

/// A rect in the decoded frames' normalized coordinate space, matching the pose keypoints it is
/// built from: both axes run 0-1 across the frame and `y` is measured down from the top edge.
///
/// Frames come out of `VideoFrameSampler` in display orientation, so pass `SampledFrame.renderSize`
/// as the pixel size for `cropRect(for:renderedPixelSize:)` and `denormalized(in:)`.
struct NormalizedRect: Equatable, Hashable, Sendable {
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float

    var width: Float { maxX - minX }
    var height: Float { maxY - minY }

    /// Scales to the rendered frame's pixel dimensions. The origin stays top-left, so a consumer
    /// that works in a bottom-left space (Core Image, `AVVideoComposition`) flips `y` itself.
    func denormalized(in pixelSize: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(minX) * pixelSize.width,
            y: CGFloat(minY) * pixelSize.height,
            width: CGFloat(width) * pixelSize.width,
            height: CGFloat(height) * pixelSize.height
        )
    }
}

/// Computes the one static rect an exported clip is cropped to, from the pose output of the
/// frames inside a single trick window (docs/DESIGN.md's pipeline step 6).
///
/// ```swift
/// let calculator = CropRectCalculator()
/// // `frame` is the `SampledFrame` the keypoints were measured against. The sampler renders in
/// // display orientation, so this is the transpose of `track.naturalSize` on portrait clips.
/// let rect = calculator.cropRect(for: framesInWindow, renderedPixelSize: frame.renderSize)
/// let pixels = rect?.denormalized(in: frame.renderSize)
/// ```
struct CropRectCalculator: Sendable {
    /// Width over height of the exported clip, in pixels.
    let targetAspectRatio: Float
    /// Fraction of the athlete's bounding box added to each of its four sides, covering both
    /// breathing room and the pose model's tendency to undershoot limbs at the frame edge.
    let paddingFraction: Float

    init(targetAspectRatio: Float = 9.0 / 16.0, paddingFraction: Float = 0.25) {
        precondition(targetAspectRatio > 0, "targetAspectRatio is width over height and must be positive")
        precondition(paddingFraction >= 0, "paddingFraction adds to each side and cannot be negative")
        self.targetAspectRatio = targetAspectRatio
        self.paddingFraction = paddingFraction
    }

    /// `nil` when the window holds no keypoint above the confidence threshold, or when the
    /// rendered-frame dimensions are unknown — in either case the athlete cannot be located in pixels.
    func cropRect(for frames: [PoseFrameResult], renderedPixelSize: CGSize) -> NormalizedRect? {
        guard renderedPixelSize.width > 0, renderedPixelSize.height > 0,
              let athlete = boundingBox(across: frames) else { return nil }

        let paddedBox = padded(athlete)
        return fittedInFrame(snappedToTargetRatio(paddedBox, renderedPixelSize: renderedPixelSize))
    }

    private func boundingBox(across frames: [PoseFrameResult]) -> NormalizedRect? {
        let located = frames.flatMap { frame in
            frame.keypoints.filter { $0.confidence > PoseKeypoint.confidenceThreshold }
        }
        guard let first = located.first else { return nil }

        return located.dropFirst().reduce(
            NormalizedRect(minX: first.x, maxX: first.x, minY: first.y, maxY: first.y)
        ) { box, keypoint in
            NormalizedRect(
                minX: min(box.minX, keypoint.x),
                maxX: max(box.maxX, keypoint.x),
                minY: min(box.minY, keypoint.y),
                maxY: max(box.maxY, keypoint.y)
            )
        }
    }

    private func padded(_ box: NormalizedRect) -> NormalizedRect {
        NormalizedRect(
            minX: box.minX - box.width * paddingFraction,
            maxX: box.maxX + box.width * paddingFraction,
            minY: box.minY - box.height * paddingFraction,
            maxY: box.maxY + box.height * paddingFraction
        )
    }

    /// Grows the shorter axis around the box center until the rect's *pixel* aspect ratio hits
    /// the target. The ratio only means anything in pixels: a normalized unit is a fraction of
    /// its own axis, so on a 1080x1920 source a normalized square is already 9:16, and a
    /// normalized 9:16 rect comes out square on 1920x1080 and 9:16 twice over on 1080x1920.
    private func snappedToTargetRatio(_ box: NormalizedRect, renderedPixelSize: CGSize) -> NormalizedRect {
        let renderedWidth = Float(renderedPixelSize.width)
        let renderedHeight = Float(renderedPixelSize.height)
        let pixelWidth = box.width * renderedWidth
        let pixelHeight = box.height * renderedHeight
        let widthAtTargetRatio = pixelHeight * targetAspectRatio

        if pixelWidth < widthAtTargetRatio {
            return box.resizedHorizontally(to: widthAtTargetRatio / renderedWidth)
        }
        return box.resizedVertically(to: pixelWidth / targetAspectRatio / renderedHeight)
    }

    /// Slides the rect back inside the frame, which preserves the ratio just snapped. An axis
    /// longer than the frame has nowhere useful to slide, so it takes the frame's full extent
    /// instead: the clip letterboxes on that axis rather than being squeezed, or re-cropped
    /// tight enough to cut the athlete off.
    private func fittedInFrame(_ box: NormalizedRect) -> NormalizedRect {
        let (minX, maxX) = fitted(lower: box.minX, upper: box.maxX)
        let (minY, maxY) = fitted(lower: box.minY, upper: box.maxY)
        return NormalizedRect(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private func fitted(lower: Float, upper: Float) -> (Float, Float) {
        let size = upper - lower
        guard size < 1 else { return (0, 1) }
        if lower < 0 { return (0, size) }
        if upper > 1 { return (1 - size, 1) }
        return (lower, upper)
    }
}

private extension NormalizedRect {
    var centerX: Float { (minX + maxX) / 2 }
    var centerY: Float { (minY + maxY) / 2 }

    func resizedHorizontally(to width: Float) -> NormalizedRect {
        NormalizedRect(minX: centerX - width / 2, maxX: centerX + width / 2, minY: minY, maxY: maxY)
    }

    func resizedVertically(to height: Float) -> NormalizedRect {
        NormalizedRect(minX: minX, maxX: maxX, minY: centerY - height / 2, maxY: centerY + height / 2)
    }
}
