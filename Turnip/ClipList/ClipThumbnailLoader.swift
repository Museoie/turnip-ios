import AVFoundation
import CoreGraphics
import Foundation

/// Builds the card thumbnails for `docs/UIUX.md` § "Clip List (triage)": the source frame
/// at each trick window's midpoint, cropped to the window's computed crop rect.
///
/// An actor so frame decoding stays off the main thread — `copyCGImage` blocks while it
/// seeks and decodes, and the review bar for this repo treats main-thread decoding as a
/// regression (it was a real past fix). `AVAsset` crosses into this actor from the
/// main-actor view; the crossing is narrow and read-only — the generator seeks and copies
/// one frame, and the asset is never mutated or stored.
actor ClipThumbnailLoader {
    /// Loads the thumbnail for `item` from `asset`.
    ///
    /// The generator returns the displayed (upright) frame, so the crop below is computed
    /// in displayed space too — no second flip. `nil` when the frame can't be decoded or
    /// the crop rect is degenerate; the card falls back to its placeholder tile.
    func thumbnail(for item: ClipListItem, in asset: AVAsset) async -> CGImage? {
        do {
            let midpoint = (item.window.startTime + item.window.endTime) / 2
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let image = try generator.copyCGImage(
                at: CMTime(seconds: midpoint, preferredTimescale: 600),
                actualTime: nil
            )
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return nil
            }
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            guard let displayedCrop = Self.displayedCropRect(
                cropRect: item.cropRect,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform
            ) else {
                return nil
            }
            let displayedSize = Self.displayedFrameSize(
                naturalSize: naturalSize, preferredTransform: preferredTransform)
            return Self.croppedThumbnail(image, to: displayedCrop, in: displayedSize)
        } catch {
            return nil
        }
    }

    /// Maps the crop rect from the encoded frame's pixel space (top-left origin, no
    /// `preferredTransform` applied — the space `NormalizedRect` and the pose keypoints
    /// live in) into the displayed frame's space, matching what `AVAssetImageGenerator`
    /// returns with `appliesPreferredTrackTransform`. `nil` for degenerate inputs.
    ///
    /// Pure so the geometry is unit-testable without an asset; the 90°-rotation test is the
    /// discriminating case, since it fails if the transform is applied in the wrong space
    /// (encoded vs. displayed).
    static func displayedCropRect(
        cropRect: NormalizedRect,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGRect? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        let encoded = cropRect.denormalized(in: naturalSize)
        guard encoded.width > 0, encoded.height > 0 else { return nil }
        return boundingBox(of: encoded.corners.map { $0.applying(preferredTransform) })
    }

    /// Crops `image` to `displayedCrop`, scaling from the displayed frame size to the
    /// image's pixel size (the generator may hand back a scaled frame when `maximumSize`
    /// is set). The crop is clamped to the image bounds and `nil` is returned when nothing
    /// survives, so a rounding slip can't produce an out-of-bounds `cropping(to:)`.
    static func croppedThumbnail(
        _ image: CGImage,
        to displayedCrop: CGRect,
        in displayedSize: CGSize
    ) -> CGImage? {
        guard displayedSize.width > 0, displayedSize.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / displayedSize.width
        let scaleY = CGFloat(image.height) / displayedSize.height
        let pixelCrop = CGRect(
            x: displayedCrop.minX * scaleX,
            y: displayedCrop.minY * scaleY,
            width: displayedCrop.width * scaleX,
            height: displayedCrop.height * scaleY
        )
        let clamped = pixelCrop.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped)
    }

    /// The displayed frame's size: the encoded frame's corners through
    /// `preferredTransform`, so a 90°-rotated track reports portrait dimensions.
    private static func displayedFrameSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        boundingBox(of: CGRect(origin: .zero, size: naturalSize).corners.map {
            $0.applying(preferredTransform)
        }).size
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension CGRect {
    var corners: [CGPoint] {
        [origin,
         CGPoint(x: maxX, y: minY),
         CGPoint(x: minX, y: maxY),
         CGPoint(x: maxX, y: maxY)]
    }
}
