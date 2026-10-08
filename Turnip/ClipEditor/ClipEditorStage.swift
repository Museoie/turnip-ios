import CoreGraphics

/// The clip editor's crop-stage geometry (`docs/UIUX.md` § "Clip Detail / Editor"): the
/// crop marker is one fixed rectangle on screen, and the video is laid out under it so the
/// clip's crop rect lands exactly on the marker — the video moves and scales per clip, the
/// marker never does. Shared by the editor's own stage and by `ClipExpansionContainer`'s
/// flying card, which must place the same player at the same spot. Pure functions, so the
/// placement is unit-testable without a view.
enum ClipEditorStage {
    /// How far the marker stays in from the stage's side edges.
    static let horizontalInset: CGFloat = 24
    /// How far the marker stays in from the stage's top and bottom edges.
    static let verticalInset: CGFloat = 12

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
    /// insets are taken off — the crop marker's frame. Independent of the clip, so it is the
    /// same rect for every clip on a given device.
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
