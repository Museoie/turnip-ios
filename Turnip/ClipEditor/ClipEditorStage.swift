import CoreGraphics

/// The clip editor's crop-stage geometry (`docs/UIUX.md` § "Clip Detail / Editor"): the
/// crop marker is one rectangle of the clip's shape on screen, and the video is laid out under
/// it so the clip's crop rect lands exactly on the marker — the video moves and scales per clip
/// and per framing; the marker changes only when its corner handles reshape it
/// (`resizedMarker`). Shared by the editor's own stage and by `ClipExpansionContainer`'s
/// flying card, which must place the same player at the same spot. Pure functions, so the
/// placement is unit-testable without a view.
enum ClipEditorStage {
    /// How far the marker stays in from the stage's side edges.
    static let horizontalInset: CGFloat = 24
    /// How far the marker stays in from the stage's top and bottom edges.
    static let verticalInset: CGFloat = 12
    /// The shapes the marker's corner handles reach, width over height: from twice as tall as
    /// wide to twice as wide as tall. Export renders at the crop rect's box at this shape
    /// (`ClipEditorViewModel.markerBox`), which only ever grows the crop rect, so a narrower
    /// bound keeps a full-frame clip's output from running to several times the frame.
    static let aspectRatioRange: ClosedRange<CGFloat> = 0.5...2
    /// The smallest a corner drag can draw the marker, on either side, in points.
    static let minimumMarkerSide: CGFloat = 64

    /// A corner of the crop marker, each with a handle that reshapes it.
    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        /// Where this corner sits on `rect`.
        func point(of rect: CGRect) -> CGPoint {
            switch self {
            case .topLeading: CGPoint(x: rect.minX, y: rect.minY)
            case .topTrailing: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeading: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomTrailing: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        /// The corner across from this one, which stays put while this one is dragged.
        var opposite: Corner {
            switch self {
            case .topLeading: .bottomTrailing
            case .topTrailing: .bottomLeading
            case .bottomLeading: .topTrailing
            case .bottomTrailing: .topLeading
            }
        }
    }

    /// `rect` shortened about its center, along its longer side, to the nearest shape in
    /// `aspectRatioRange`; unchanged when it is already in range.
    static func clampedShape(_ rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return rect }
        let width = min(rect.width, rect.height * aspectRatioRange.upperBound)
        let height = min(rect.height, width / aspectRatioRange.lowerBound)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// `marker` with `corner` dragged by `translation` and the corner across from it held still:
    /// kept inside `stage` less the marker's insets, at least `minimumMarkerSide` on each side,
    /// and within `aspectRatioRange`, which pulls the dragged corner back toward the held one
    /// along the side that runs over.
    static func resizedMarker(_ marker: CGRect, corner: Corner, translation: CGSize, in stage: CGRect) -> CGRect {
        let available = stage.insetBy(dx: horizontalInset, dy: verticalInset)
        let anchor = corner.opposite.point(of: marker)
        let start = corner.point(of: marker)
        // +1 where the dragged corner lies right of / below the held one.
        let towardX: CGFloat = start.x >= anchor.x ? 1 : -1
        let towardY: CGFloat = start.y >= anchor.y ? 1 : -1
        let dragged = CGPoint(
            x: min(max(start.x + translation.width, available.minX), available.maxX),
            y: min(max(start.y + translation.height, available.minY), available.maxY))
        var width = max((dragged.x - anchor.x) * towardX, minimumMarkerSide)
        var height = max((dragged.y - anchor.y) * towardY, minimumMarkerSide)
        width = min(width, height * aspectRatioRange.upperBound)
        height = min(height, width / aspectRatioRange.lowerBound)
        return CGRect(
            x: towardX > 0 ? anchor.x : anchor.x - width,
            y: towardY > 0 ? anchor.y : anchor.y - height,
            width: width, height: height)
    }

    /// Where the video is laid out on the stage, and how its displayed pixels map to points.
    struct VideoPlacement: Equatable {
        /// The whole displayed frame's rect, in the stage's coordinates — routinely wider or
        /// taller than the screen, since the crop rect alone has to fill the marker.
        let frame: CGRect
        /// On-screen points per displayed pixel: the uniform scale that maps the crop rect
        /// onto the marker. `applyCropOffset(_:previewScale:)`'s unit conversion.
        let pointsPerDisplayedPixel: CGFloat
    }

    /// The largest rect of `aspectRatio` (width over height) centered in `stage` once the
    /// insets are taken off — the crop marker's frame. It depends on the clip only through its
    /// shape, so every clip of one shape has the same rect on a given device.
    static func markerRect(in stage: CGRect, aspectRatio: CGFloat) -> CGRect {
        let available = stage.insetBy(dx: horizontalInset, dy: verticalInset)
        guard available.width > 0, available.height > 0, aspectRatio > 0 else {
            return CGRect(origin: CGPoint(x: stage.midX, y: stage.midY), size: .zero)
        }
        var size = CGSize(width: available.width, height: available.width / aspectRatio)
        if size.height > available.height {
            size = CGSize(width: available.height * aspectRatio, height: available.height)
        }
        return CGRect(
            x: available.midX - size.width / 2, y: available.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    /// Lays the displayed frame (`videoSize`, in displayed pixels) out so `cropRect` (in the
    /// same pixel space) fills `marker`: one uniform scale fits the crop rect inside the
    /// marker — exactly, when the two share an aspect ratio, which `CropRectCalculator`
    /// guarantees for its own rects — and the crop rect's center lands on the marker's.
    /// `nil` for degenerate inputs.
    static func videoPlacement(videoSize: CGSize, cropRect: CGRect, marker: CGRect) -> VideoPlacement? {
        guard videoSize.width > 0, videoSize.height > 0,
              cropRect.width > 0, cropRect.height > 0,
              marker.width > 0, marker.height > 0
        else { return nil }
        let scale = min(marker.width / cropRect.width, marker.height / cropRect.height)
        let frame = CGRect(
            x: marker.midX - cropRect.midX * scale,
            y: marker.midY - cropRect.midY * scale,
            width: videoSize.width * scale,
            height: videoSize.height * scale)
        return VideoPlacement(frame: frame, pointsPerDisplayedPixel: scale)
    }
}
