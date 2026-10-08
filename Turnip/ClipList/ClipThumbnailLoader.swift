import AVFoundation
import CoreGraphics
import Foundation

/// Builds the card thumbnails for `docs/UIUX.md` § "Clip List (triage)": the source frame
/// at each trick window's midpoint, cropped to the window's computed crop rect and
/// transformed by the editor's manual crop adjustment (rotate/zoom/pan), exactly as
/// `ClipExporter` renders it.
///
/// An actor so frame decoding stays off the main thread — `copyCGImage` blocks while it
/// seeks and decodes, and the review bar for this repo treats main-thread decoding as a
/// regression (it was a real past fix). `AVAsset` crosses into this actor from the
/// main-actor view; the crossing is narrow and read-only — the generator seeks and copies
/// one frame, and the asset is never mutated or stored.
actor ClipThumbnailLoader {
    /// Loads the thumbnail for `item` from `asset`.
    ///
    /// The generator returns the raw, un-uprighted frame: `ClipExportTransform.make`
    /// already composes `preferredTransform` into `layerTransform`, the same as the
    /// export path, so applying it here too would rotate the frame twice. `nil` when the
    /// frame can't be decoded or the crop rect is degenerate; the card falls back to its
    /// placeholder tile.
    ///
    /// Cooperative cancellation: `Task.isCancelled` is checked once, before the decode
    /// starts, so a cancelled caller bails before the expensive seek+decode. After that
    /// the decode runs to completion and the result is cached — deliberately:
    /// `copyCGImage` blocks and is not cancellable, so a later checkpoint cannot save
    /// the expensive work, it can only discard a result another card may be waiting on
    /// (cards share one in-flight decode per id through the view model's dedup).
    func thumbnail(for item: ClipListItem, in asset: AVAsset) async -> CGImage? {
        do {
            // Fail fast on assets with no video track: seeking a frame that can't exist
            // is wasted work, and the placeholder tile is the honest fallback.
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return nil
            }
            if Task.isCancelled { return nil }
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let midpoint = (item.window.startTime + item.window.endTime) / 2
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = false
            // Exact seek: the default infinite tolerances let the generator return the
            // nearest keyframe, which can sit outside the trick window — but the crop
            // rect was derived from the athlete's pose *inside* the window.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // The bound applies to the raw (un-uprighted) frame this generator now
            // returns, so a 90°/270°-rotated track needs it transposed — otherwise a
            // portrait-shaped bound clips a landscape-encoded frame's long edge.
            generator.maximumSize = Self.encodedMaxPixelSize(preferredTransform: preferredTransform)
            let image = try generator.copyCGImage(
                at: CMTime(seconds: midpoint, preferredTimescale: 600),
                actualTime: nil
            )
            return Self.adjustedThumbnail(
                from: image,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                cropRect: item.cropRect,
                cropAdjustment: item.cropAdjustment,
                maxPixelSize: Self.defaultMaxPixelSize
            )
        } catch {
            return nil
        }
    }

    /// Decoded-frame bound for card thumbnails: the two-column triage grid gives ~170pt
    /// cards on a ~390pt phone, at 9:16 and @3x. Unbounded, the generator and the render
    /// context below hand back native-resolution frames and the view model holds one per
    /// visible card resident. `adjustedThumbnail` scales its render context to this bound,
    /// so this caps both decode and render memory.
    static let defaultMaxPixelSize = CGSize(width: 512, height: 912)

    /// `defaultMaxPixelSize`, transposed for a track whose `preferredTransform` swaps
    /// axes (a 90°/270° rotation: `a` and `d` are both zero). The generator this bounds
    /// now returns the raw, un-uprighted frame, so the bound has to be sized in *that*
    /// frame's orientation — not the displayed one `defaultMaxPixelSize` was chosen for.
    static func encodedMaxPixelSize(preferredTransform: CGAffineTransform) -> CGSize {
        guard preferredTransform.a == 0, preferredTransform.d == 0 else {
            return defaultMaxPixelSize
        }
        return CGSize(width: defaultMaxPixelSize.height, height: defaultMaxPixelSize.width)
    }

    // Every parameter is one input `ClipExportTransform.make` itself already takes, plus
    // the decoded image and the thumbnail's own memory bound — grouping them behind a
    // struct would move the same six values without reducing what a caller supplies.
    // swiftlint:disable function_parameter_count
    /// Renders `image` — the raw, un-uprighted decoded frame — through the same
    /// composited crop-and-adjustment geometry `ClipExporter` uses for export, so the
    /// card thumbnail and the exported clip always agree on the framing.
    ///
    /// `ClipExportTransform.layerTransform` targets AVFoundation's video-composition
    /// render space: top-left origin, y-down, the same convention `preferredTransform`
    /// and `NormalizedRect` use. A `CGContext` is the opposite — bottom-left origin,
    /// y-up — so two flips are needed, one on each side of `layerTransform`. The outer
    /// flip (applied first, below) turns the context's own bottom-left/y-up device space
    /// into `layerTransform`'s top-left/y-down render space. The inner flip (applied
    /// last, right before `draw`) undoes `CGContext.draw(_:in:)`'s own behavior: it
    /// places `image`'s first data row at the *high*-y edge of its destination rect in
    /// whatever space is current at the call site, so without this second flip
    /// `layerTransform` would be handed a vertically mirrored source. `layerTransform`'s
    /// own render size is in the source's full-resolution pixels, which would blow the
    /// per-card memory budget `defaultMaxPixelSize` guards, so the context is
    /// additionally scaled down to fit within `maxPixelSize` — a uniform scale, so it
    /// doesn't disturb either flip or the transform's rotation.
    ///
    /// `nil` when the crop rect is degenerate, the scaled render size is non-finite, or
    /// the context can't be created.
    static func adjustedThumbnail(
        from image: CGImage,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        cropRect: NormalizedRect,
        cropAdjustment: CropAdjustment,
        maxPixelSize: CGSize
    ) -> CGImage? {
        // swiftlint:enable function_parameter_count
        guard let transform = ClipExportTransform.make(
            cropRect: cropRect,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            cropAdjustment: cropAdjustment
        ), transform.renderSize.width > 0, transform.renderSize.height > 0 else {
            return nil
        }

        let scale = min(
            1,
            maxPixelSize.width / transform.renderSize.width,
            maxPixelSize.height / transform.renderSize.height
        )
        guard scale.isFinite, scale > 0 else { return nil }
        let pixelWidth = max(1, Int((transform.renderSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((transform.renderSize.height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Black where the crop reaches past the frame — a zoomed-out/rotated adjustment, or
        // the 9:16 marker around a hand-added clip's full-frame rect — the same thing the
        // export's video composition renders there, so the tile and the exported clip agree
        // on the letterbox.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // Outer flip into layerTransform's top-left/y-down space, then scale down to the
        // bounded pixel size, then apply the composited crop/adjustment transform.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.concatenate(transform.layerTransform)
        // Inner flip: undoes draw(_:in:)'s own placement of image data at the high-y
        // edge of its rect, so layerTransform (already concatenated above) receives an
        // unmirrored source in its own coordinate space.
        context.translateBy(x: 0, y: naturalSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: naturalSize))

        return context.makeImage()
    }

    /// Maps the crop rect from `NormalizedRect`'s space contract — the decoded frames'
    /// normalized space (display orientation, y down from the top), matching the pose
    /// keypoints it is built from — into displayed pixel space, matching what
    /// `AVAssetImageGenerator` returns with `appliesPreferredTrackTransform`.
    /// `nil` for degenerate inputs.
    ///
    /// Pure so the geometry is unit-testable without an asset; the 90°-rotation test is the
    /// discriminating case, since it fails if the rect is denormalized in the wrong space
    /// (encoded vs. displayed).
    static func displayedCropRect(
        cropRect: NormalizedRect,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGRect? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        // cropRect is already normalized in display orientation, so denormalize in the
        // displayed size directly — no trip through preferredTransform needed.
        let displayedSize = naturalSize.displayed(through: preferredTransform)
        let displayed = cropRect.denormalized(in: displayedSize)
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        return displayed
    }

    /// The aspect ratio (width / height) of `cropRect` alone, in the displayed frame's
    /// space, before any editor adjustment — `cropAdjustment` transforms the content
    /// inside the crop, never the crop rect's own marker size, so this ratio still
    /// matches what the decoded thumbnail renders at. Falls back to 9:16 for degenerate
    /// inputs.
    static func displayedAspectRatio(
        cropRect: NormalizedRect,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGFloat {
        guard let displayed = displayedCropRect(
            cropRect: cropRect,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        ), displayed.height > 0 else {
            return 9.0 / 16.0
        }
        return displayed.width / displayed.height
    }
}
