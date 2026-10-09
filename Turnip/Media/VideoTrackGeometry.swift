import CoreGraphics

/// A video track's encoded frame and the transform that uprights it for display — the one
/// place the displayed (upright) frame is derived from `naturalSize` + `preferredTransform`.
///
/// iPhone portrait recordings are landscape-encoded with a 90° `preferredTransform`, so the
/// displayed frame is the encoded frame's bounding box through that transform: its size is
/// `naturalSize` transposed. Everything that decodes, previews, crops or exports a frame has to
/// agree on that space, since `NormalizedRect` crop rects and pose keypoints are normalized in
/// it — denormalizing them in the encoded size silently lands on the wrong region.
struct VideoTrackGeometry: Equatable {
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform

    /// The encoded frame's bounding box through `preferredTransform`. Not necessarily at the
    /// origin: a transform that rotates about the origin places the content at negative
    /// coordinates, which `uprightTransform` normalizes away.
    var displayedBounds: CGRect {
        CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    }

    /// The frame size as the player shows it, so a 90°-rotated track reports portrait
    /// dimensions.
    var displayedSize: CGSize {
        displayedBounds.size
    }

    /// Maps encoded-frame coordinates into origin-based displayed space, `[0, displayedSize]`.
    /// Camera-roll assets carry the normalizing translation in `preferredTransform` already;
    /// imported and edited ones need not, and without it a composition renders correctly sized
    /// frames of pure background.
    var uprightTransform: CGAffineTransform {
        let bounds = displayedBounds
        return preferredTransform.concatenating(
            CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }

    /// `cropRect`, normalized in display orientation (y down from the top) per
    /// `NormalizedRect`'s space contract, in displayed pixels. Denormalized against the
    /// displayed size directly — no trip through `preferredTransform`. `nil` for an unknown
    /// frame size or a degenerate rect.
    func displayedCropRect(_ cropRect: NormalizedRect) -> CGRect? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        let displayed = cropRect.denormalized(in: displayedSize)
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        return displayed
    }
}
