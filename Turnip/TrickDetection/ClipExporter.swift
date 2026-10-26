import AVFoundation
import CoreGraphics
import Foundation

/// One detected clip to export: its time window in the source video and the static crop rect
/// for it (docs/DESIGN.md's pipeline steps 5-6 feeding step 7).
///
/// `cropRect` is normalized in *display* orientation — the decoded frames' normalized space,
/// matching the pose keypoints it is computed from (`VideoFrameSampler` applies the track's
/// `preferredTransform` when sampling, so keypoints are measured upright). Pass
/// `SampledFrame.renderSize` (not `track.naturalSize`) when denormalizing it.
///
/// `followCrop`, when set, replaces `cropAdjustment`: the crop moves with the athlete along
/// it (`docs/DESIGN.md` step 6, "Follow crop in the editor"), with `cropRect` setting only the
/// crop's size, the marker's.
struct ClipSpec: Equatable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
    let cropAdjustment: CropAdjustment
    let followCrop: FollowCrop?

    init(
        window: TrickWindow, cropRect: NormalizedRect, cropAdjustment: CropAdjustment = .identity,
        followCrop: FollowCrop? = nil
    ) {
        self.window = window
        self.cropRect = cropRect
        self.cropAdjustment = cropAdjustment
        self.followCrop = followCrop
    }
}

/// A successfully exported clip.
struct ExportedClip: Sendable {
    let fileURL: URL
}

/// Failures a clip export can hit, typed so callers can tell a bad window (skip the clip)
/// from an export-session failure (retryable) without parsing strings.
enum ClipExportError: LocalizedError, Equatable {
    case noVideoTrack
    case invalidTimeRange(window: TrickWindow)
    case invalidCropRect(window: TrickWindow)
    case exportFailed(reason: String)
    case cancelled

    /// Human-readable copy for every case. The adapters that carry these errors to the
    /// user (`exportOneClip` in `ClipListViewModel`) flatten them with
    /// `localizedDescription`, so without this conformance every typed export failure
    /// would surface as Swift's NSError-bridge placeholder ("The operation couldn't be
    /// completed. (Turnip.ClipExportError error N.)") instead of a sentence — the same
    /// flattening `ClipPhotosSaveError`'s own `LocalizedError` conformance already
    /// fixed on the Photos side.
    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "This video has no video track to export."
        case .invalidTimeRange:
            return "This clip's time window is outside the video, so it couldn't be exported."
        case .invalidCropRect:
            return "This clip's crop area is invalid, so it couldn't be exported."
        case .exportFailed(let reason):
            return "Couldn't export this clip. (\(reason))"
        case .cancelled:
            return "The export was cancelled."
        }
    }
}

/// One stretch of a moving crop: across `timeRange` the layer transform slides linearly from
/// `start` to `end`, which is what `setTransformRamp` draws.
struct ClipTransformRamp: Equatable {
    let timeRange: CMTimeRange
    let start: CGAffineTransform
    let end: CGAffineTransform
}

/// The render geometry for one exported clip, computed from pure inputs — no AVFoundation
/// session required, so it is unit-testable.
struct ClipExportTransform {
    /// Output frame size in pixels.
    let renderSize: CGSize
    /// Maps the source video track's coordinates onto the composition's render space: for the
    /// whole clip when `ramps` is empty, and at time zero when it isn't.
    let layerTransform: CGAffineTransform
    /// A moving crop's transform over time, in composition time and in order, the first
    /// starting at zero. Empty for a static crop.
    var ramps: [ClipTransformRamp] = []

    /// Builds the crop transform for `cropRect`.
    ///
    /// `cropRect` is normalized in the *displayed* (upright) frame's space — the same space
    /// as the pose keypoints it is computed from, since the frame sampler applies the
    /// track's `preferredTransform` when decoding. It is denormalized against the displayed
    /// size (`VideoTrackGeometry`), not `naturalSize`: on a 90°-rotated track those differ by a transpose, and
    /// denormalizing a display-normalized rect in the encoded size silently crops the wrong
    /// region. The layer transform therefore uprights the encoded frame into origin-based
    /// displayed space and then translates the crop's displayed top-left corner to the
    /// origin. There is no Y-flip: an `AVMutableVideoCompositionLayerInstruction` transform
    /// maps into a top-left-origin render space, the same space `preferredTransform`
    /// already targets — the bottom-left convention belongs to Core Image and to
    /// `AVVideoCompositionCoreAnimationTool` overlay layers, neither of which is in play
    /// here. The crop is never scaled: the output frame is exactly the crop rect's size,
    /// rounded up to even H.264 dimensions, per the design doc's "crop, not
    /// scale-and-letterbox".
    ///
    /// `nil` when the source dimensions are unknown or the crop rect is degenerate — in
    /// either case there is no frame to render into.
    ///
    /// `cropAdjustment` is the editor's manual pinch/rotate/drag on top of `cropRect`: the
    /// crop rect's on-screen marker stays fixed, so the adjustment transforms the *video*
    /// around the rect's center, and the export has to reproduce that exactly — the
    /// render frame stays `cropRect`'s own size, only the source content landing inside it
    /// changes. At `.identity` this reduces to the un-adjusted crop translation.
    static func make(
        cropRect: NormalizedRect,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        cropAdjustment: CropAdjustment = .identity
    ) -> ClipExportTransform? {
        // The crop is already in displayed space (`VideoTrackGeometry`), so after the upright
        // transform its top-left subtracts directly — no second trip through preferredTransform.
        let geometry = VideoTrackGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform)
        guard let crop = geometry.displayedCropRect(cropRect) else { return nil }
        return make(displayedCrop: crop, geometry: geometry, cropAdjustment: cropAdjustment)
    }

    /// `make(cropRect:…)` for a crop already in displayed pixels.
    private static func make(
        displayedCrop crop: CGRect, geometry: VideoTrackGeometry, cropAdjustment: CropAdjustment
    ) -> ClipExportTransform? {
        guard crop.width > 0, crop.height > 0 else { return nil }
        // Maps upright displayed-space points into the crop's render space, anchored on
        // the crop rect's own center so the preview's fixed marker rectangle and this
        // export transform agree: un-anchor, apply the user's scale/rotation about the
        // origin (they commute — both are uniform/linear), then re-anchor and land the
        // crop's top-left at the render origin. At identity (scale 1, no rotation, no
        // offset) this is exactly `translate(-crop.minX, -crop.minY)`, the un-adjusted
        // crop translation.
        let anchor = CGPoint(x: crop.midX, y: crop.midY)
        let cropTransform = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(rotationAngle: cropAdjustment.rotationRadians))
            .concatenating(CGAffineTransform(scaleX: cropAdjustment.scale, y: cropAdjustment.scale))
            .concatenating(CGAffineTransform(
                translationX: anchor.x + cropAdjustment.offset.width - crop.minX,
                y: anchor.y + cropAdjustment.offset.height - crop.minY))
        let layerTransform = geometry.uprightTransform.concatenating(cropTransform)

        // H.264 requires integral, even width and height, and the crop math above is
        // float — round here. The layer transform already pins the crop's displayed
        // top-left to the render origin, so widening the frame only pads the
        // right/bottom edges; the translation stays consistent with the rounded size.
        let renderSize = CGSize(
            width: crop.width.roundedToEvenDimensions,
            height: crop.height.roundedToEvenDimensions)

        return ClipExportTransform(renderSize: renderSize, layerTransform: layerTransform)
    }

    // swiftlint:disable function_parameter_count
    /// The transform for a follow crop over `span`, a range of source time that composition
    /// time zero sits at the start of — the trimmed clip's range for an export, `0...duration`
    /// for a player over the untrimmed source.
    ///
    /// At every moment the crop is a box of the marker's size (`cropRect`'s marker box)
    /// centered on the follow crop's center then, zoomed and turned about that center by the
    /// zoom and turn then — the order the editor's preview draws. Wherever the crop moves, it is
    /// sampled on every frame of the composition's grid, `frameDuration` apart from composition
    /// time zero, one ramp per frame. The composition interpolates a ramp's matrix linearly
    /// between its two ends, which shears the picture partway through a ramp whose turn or zoom
    /// changes, so each frame the composition renders has to land on a ramp's start, drawn
    /// exactly: `frameDuration` must be the composition's own (`makeVideoComposition`). Where
    /// the crop holds, one ramp covers the hold.
    ///
    /// `nil` when the source dimensions are unknown or the crop rect is degenerate.
    static func make(
        followCrop: FollowCrop,
        cropRect: NormalizedRect,
        over span: ClosedRange<TimeInterval>,
        frameDuration: CMTime,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> ClipExportTransform? {
        // swiftlint:enable function_parameter_count
        let geometry = VideoTrackGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform)
        guard let crop = geometry.displayedCropRect(cropRect) else { return nil }
        let box = ClipEditorViewModel.markerBox(
            around: crop, aspectRatio: CGFloat(CropRectCalculator().targetAspectRatio)).size
        let path = followCrop.path
        var stops: [(time: CMTime, transform: ClipExportTransform)] = []
        for time in sampleTimes(over: span, moving: path.movingSpan, frameDuration: frameDuration) {
            let framing = path.framing(at: span.lowerBound + time.seconds)
            let rect = CGRect(
                x: framing.center.x - box.width / 2, y: framing.center.y - box.height / 2,
                width: box.width, height: box.height)
            let adjustment = CropAdjustment(
                scale: framing.scale, rotationRadians: framing.rotationRadians, offset: .zero)
            guard let transform = make(displayedCrop: rect, geometry: geometry, cropAdjustment: adjustment)
            else { return nil }
            stops.append((time, transform))
        }
        guard let first = stops.first else { return nil }
        let ramps = zip(stops, stops.dropFirst()).map { earlier, later in
            ClipTransformRamp(
                timeRange: CMTimeRange(start: earlier.time, end: later.time),
                start: earlier.transform.layerTransform,
                end: later.transform.layerTransform)
        }
        return ClipExportTransform(
            renderSize: first.transform.renderSize, layerTransform: first.transform.layerTransform,
            ramps: ramps)
    }

    /// Where a follow crop is sampled, in composition time: zero, the span's end, and every frame
    /// of the composition's grid — whole multiples of `frameDuration`, exact rather than rounded
    /// — from the last frame before the crop starts moving to the first after it stops.
    static func sampleTimes(
        over span: ClosedRange<TimeInterval>, moving: ClosedRange<TimeInterval>?, frameDuration: CMTime
    ) -> [CMTime] {
        // Rounded to the timescale rather than through `CMTime(seconds:preferredTimescale:)`,
        // which truncates.
        let end = CMTime(value: CMTimeValue(((span.upperBound - span.lowerBound) * 600).rounded()), timescale: 600)
        var times = [CMTime.zero]
        let frame = frameDuration.seconds
        if let moving, frameDuration.isNumeric, frame > 0 {
            let firstIndex = Int(((moving.lowerBound - span.lowerBound) / frame).rounded(.down))
            let lastIndex = Int(((moving.upperBound - span.lowerBound) / frame).rounded(.up))
            for index in max(firstIndex, 1)...max(lastIndex, 1) {
                let time = CMTimeMultiply(frameDuration, multiplier: Int32(clamping: index))
                if CMTimeCompare(time, end) < 0 { times.append(time) }
            }
        }
        if let last = times.last, CMTimeCompare(end, last) > 0 { times.append(end) }
        return times
    }

    /// Builds an `AVMutableVideoComposition` applying this transform to `track`, covering
    /// `duration` from the start with a single instruction — shared by `ClipExporter`
    /// (over a trimmed composition track) and the clip list's live preview player (over
    /// the untrimmed source track; `AVPlayerLooper`'s own `timeRange` bounds what
    /// actually loops, this only shapes the frame). The output grid comes from
    /// `VideoFrameSampler.compositionFrameDuration`: the track's exact
    /// `minFrameDuration` when it is usable, otherwise the nominal rate's grid.
    /// The derivation rejects a rate that rounds below 1 fps, a rate past
    /// `Int32.max`, and the nominal average when an exact spacing exists.
    /// Throws `PoseError.videoLoadFailed` when neither timing value yields a
    /// valid grid; callers map that onto their own error type.
    func makeVideoComposition(
        for track: AVAssetTrack, duration: CMTime, frameRate: Float, minFrameDuration: CMTime
    ) throws -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = try VideoFrameSampler.compositionFrameDuration(
            minFrameDuration: minFrameDuration, nominalFrameRate: frameRate)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // A moving crop's first ramp starts at zero, and a fixed transform set at the same time
        // would compete with it.
        if ramps.isEmpty {
            layerInstruction.setTransform(layerTransform, at: .zero)
        }
        for ramp in ramps {
            layerInstruction.setTransformRamp(fromStart: ramp.start, toEnd: ramp.end, timeRange: ramp.timeRange)
        }
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        return videoComposition
    }
}

private extension CGFloat {
    /// Smallest even integer no smaller than self, and at least 2 — H.264 requires even
    /// frame dimensions, and a sub-two-pixel frame has nothing to encode. Rounding up
    /// rather than to nearest keeps the widening one-directional, which is what lets the
    /// pinned crop origin pad the right/bottom edges instead of clipping them.
    /// `Swift.max` is qualified: unqualified `max` inside this extension resolves to
    /// `CGFloat.max`.
    var roundedToEvenDimensions: CGFloat {
        Swift.max(2, (self / 2).rounded(.up) * 2)
    }
}

private extension AVAssetExportSession.Status {
    var isTerminal: Bool {
        self == .completed || self == .cancelled || self == .failed
    }
}

/// `AVAssetExportSession` is not `Sendable`, yet the task-cancellation handler and the
/// progress poller below must both be `@Sendable`. The session is created and driven from
/// this actor, and the box only crosses into the cancellation handler (which runs at most
/// once, after cancellation) and the progress poller (which only reads `progress`/`status`,
/// both safe to read off the driving context). That narrow, documented crossing is why the
/// box is `@unchecked Sendable` rather than the session being shared freely.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// Where one clip's ranges land in the composition: the video range cut from the
/// trim window, with the audio range subordinate to it (intersected with the video
/// range and inserted at its offset from the video range's start). A small struct
/// rather than a tuple so the three members stay named and documented together.
struct ClipInsertRanges {
    /// The video track's range in the composition.
    let video: CMTimeRange
    /// The audio track's range, already intersected with the video range.
    let audio: CMTimeRange
    /// Offset of the audio range's start from the video range's start.
    let audioOffset: CMTime
}

/// Exports detected clips: trims the source video to each trick window, crops to its rect,
/// keeps the source's audio over the same range, and writes an `.mp4` per clip
/// (docs/DESIGN.md's pipeline step 7).
///
/// An actor so the `AVAssetExportSession` — which is not `Sendable` — stays confined off the
/// main thread while exports run; per-frame decoding and encoding never touch the main
/// thread. The exporter is UI-independent: it takes clip specs and returns file URLs, and the
/// clip list's Save Clips or a test calls it the same way. Writing the files to Photos is
/// `ClipPhotosSaver`'s job, and the caller owns the output directory (and cleaning it up).
actor ClipExporter {
    /// Per-clip progress: 0.0-1.0 fraction of this clip's export completed.
    typealias ProgressHandler = @Sendable (Double) -> Void

    /// Clamps a trick window to the asset's duration. `nil` when nothing survives the clamp —
    /// a window entirely past the end of the video, or with its start at/after its end.
    /// Pure and unit-testable: the export path never trims a range it hasn't clamped here.
    static func trimmedRange(for window: TrickWindow, duration: TimeInterval) -> ClosedRange<TimeInterval>? {
        let start = max(0, window.startTime)
        let end = min(duration, window.endTime)
        guard start < end else { return nil }
        return start...end
    }

    /// Where one clip's ranges land in the composition, computed from pure inputs — no
    /// asset or export session needed, so it is unit-testable.
    ///
    /// The audio range is *subordinate* to the video range, not parallel to it: it is
    /// intersected with the video range and inserted at its offset from the video range's
    /// start. Inserting both tracks at `.zero` turns any difference between the tracks'
    /// start times into a fixed A/V offset for the whole clip (real on recordings whose
    /// audio track starts during capture ramp-up), and an audio range computed
    /// independently of the video range can outrun the video into a tail with no picture
    /// (real when the audio track runs past the last video sample).
    ///
    /// `nil` when the trimmed range holds no video — a deterministic property of
    /// (window, asset), so the caller reports `invalidTimeRange` (skip the clip) rather
    /// than the retryable `exportFailed`.
    static func insertRanges(
        trim: CMTimeRange,
        videoTrack: CMTimeRange,
        audioTrack: CMTimeRange?
    ) -> ClipInsertRanges? {
        let video = trim.intersection(videoTrack)
        guard video.duration > .zero else { return nil }
        var audio = CMTimeRange(start: .zero, duration: .zero)
        var audioOffset = CMTime.zero
        if let audioTrack {
            let range = trim.intersection(audioTrack).intersection(video)
            if range.duration > .zero {
                audio = range
                audioOffset = range.start - video.start
            }
        }
        return ClipInsertRanges(video: video, audio: audio, audioOffset: audioOffset)
    }

    /// Exports one clip. Throws `ClipExportError`, or the underlying AVFoundation
    /// error from asset loading; a stale file at the output URL is removed before the
    /// export starts (a failed or cancelled attempt leaves its partial file behind, and
    /// the session refuses to overwrite — without this the retry the error type
    /// advertises as retryable would fail with `AVErrorFileAlreadyExists`), while the
    /// output file is left in place on failure for debugging and the caller decides
    /// whether to delete it afterwards.
    ///
    /// `fileName` must be a single path component (no slashes): it is appended to
    /// `directory`, so a `../` would escape the caller's output directory.
    func export(
        _ spec: ClipSpec,
        from asset: AVAsset,
        to directory: URL,
        fileName: String? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> ExportedClip {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        guard let range = Self.trimmedRange(for: spec.window, duration: duration) else {
            throw ClipExportError.invalidTimeRange(window: spec.window)
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        guard let staticTransform = ClipExportTransform.make(
            cropRect: spec.cropRect, naturalSize: naturalSize, preferredTransform: preferredTransform,
            cropAdjustment: spec.cropAdjustment
        ) else {
            throw ClipExportError.invalidCropRect(window: spec.window)
        }

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        // The ranges are computed here, where spec.window is in hand, so an empty video
        // range reports invalidTimeRange (a deterministic bad window), not the retryable
        // exportFailed.
        let videoTrackRange = try await videoTrack.load(.timeRange)
        let audioTrackRange = try await audioTrack?.load(.timeRange)
        guard let ranges = Self.insertRanges(
            trim: timeRange, videoTrack: videoTrackRange, audioTrack: audioTrackRange)
        else {
            throw ClipExportError.invalidTimeRange(window: spec.window)
        }
        let (frameRate, minFrameDuration) = try await Self.frameTiming(of: videoTrack)
        let transform = try Self.renderTransform(
            for: spec, staticTransform: staticTransform, videoRange: ranges.video, frameRate: frameRate,
            minFrameDuration: minFrameDuration, naturalSize: naturalSize, preferredTransform: preferredTransform)
        let composition = try makeComposition(
            videoTrack: videoTrack, audioTrack: audioTrack, ranges: ranges)
        let videoComposition = try makeVideoComposition(
            in: composition, transform: transform, frameRate: frameRate,
            minFrameDuration: minFrameDuration)

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw ClipExportError.exportFailed(reason: "could not create an export session")
        }
        let outputURL = directory
            .appendingPathComponent(fileName ?? UUID().uuidString)
            .appendingPathExtension("mp4")
        try Self.removeExistingFile(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = videoComposition

        try await runExport(session, progress: progress)
        return ExportedClip(fileURL: outputURL)
    }

    // swiftlint:disable function_parameter_count
    /// The static crop's transform, or — for a spec with a follow crop — the moving crop's,
    /// timed against the composition, which starts where the trimmed video range does, and
    /// sampled on the composition's own frame grid: the one `makeVideoComposition` derives from
    /// the same `frameRate` and `minFrameDuration`.
    static func renderTransform(
        for spec: ClipSpec, staticTransform: ClipExportTransform, videoRange: CMTimeRange, frameRate: Float,
        minFrameDuration: CMTime, naturalSize: CGSize, preferredTransform: CGAffineTransform
    ) throws -> ClipExportTransform {
        // swiftlint:enable function_parameter_count
        guard let followCrop = spec.followCrop else { return staticTransform }
        let frameDuration: CMTime
        do {
            frameDuration = try VideoFrameSampler.compositionFrameDuration(
                minFrameDuration: minFrameDuration, nominalFrameRate: frameRate)
        } catch {
            throw ClipExportError.exportFailed(reason: "could not determine a valid frame duration")
        }
        guard let moving = ClipExportTransform.make(
            followCrop: followCrop, cropRect: spec.cropRect,
            over: videoRange.start.seconds...videoRange.end.seconds, frameDuration: frameDuration,
            naturalSize: naturalSize, preferredTransform: preferredTransform)
        else {
            throw ClipExportError.invalidCropRect(window: spec.window)
        }
        return moving
    }

    /// The track's timing values the export lays its frame grid out from: `exportFrameRate`'s rate
    /// and the track's own `minFrameDuration`.
    private static func frameTiming(
        of track: AVAssetTrack
    ) async throws -> (frameRate: Float, minFrameDuration: CMTime) {
        let (nominalFrameRate, minFrameDuration) = try await track.load(.nominalFrameRate, .minFrameDuration)
        let frameRate = exportFrameRate(nominalFrameRate: nominalFrameRate, minFrameDuration: minFrameDuration)
        return (frameRate, minFrameDuration)
    }

    /// The nominal rate the export lays its frame grid out from: the track's own, or 30 fps for a
    /// track with no usable timing value at all (nominal rate 0 and no usable
    /// `minFrameDuration`), which exports on a 30 fps grid. Only the export path falls back: the
    /// shared derivation (`VideoFrameSampler.compositionFrameDuration`) keeps its throw contract,
    /// so the preview still drops to the uncomposed player, and sub-0.5 fps or over-`Int32.max`
    /// rates still throw.
    static func exportFrameRate(nominalFrameRate: Float, minFrameDuration: CMTime) -> Float {
        let hasUsableSpacing = minFrameDuration.isNumeric && minFrameDuration.seconds > 0
        return (!hasUsableSpacing && nominalFrameRate <= 0) ? 30 : nominalFrameRate
    }

    /// Deletes any file already at `url`. Export sessions refuse to write over an
    /// existing file, and both failure and `cancelExport()` leave the partial file
    /// behind — without this, the retry the error type advertises as retryable fails
    /// with `AVErrorFileAlreadyExists`.
    static func removeExistingFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The trimmed timeline: the source video track, cut to its range, with the source's
    /// audio track laid over the same range. Exported clips keep their audio: the design
    /// doc's share path hands the file to Instagram / TikTok / YouTube Shorts, where a
    /// silent clip reads as broken. A source with no audio track exports silent.
    ///
    /// The ranges come from `insertRanges`, already reconciled: the audio is intersected
    /// with the video range and inserted at its offset from the video range's start, so
    /// the clip can neither drift out of A/V sync nor end with audio and no picture.
    private func makeComposition(
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        ranges: ClipInsertRanges
    ) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw ClipExportError.exportFailed(reason: "could not add a video track to the composition")
        }
        try compositionTrack.insertTimeRange(ranges.video, of: videoTrack, at: .zero)
        if let audioTrack, ranges.audio.duration > .zero {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                throw ClipExportError.exportFailed(
                    reason: "could not add an audio track to the composition")
            }
            try compositionAudioTrack.insertTimeRange(
                ranges.audio, of: audioTrack, at: ranges.audioOffset)
        }
        return composition
    }

    /// The crop: one instruction covering the whole composition, applying the render
    /// transform at time zero, or a moving crop's ramps from there. The instruction's range is
    /// the composition's full duration — the composition holds exactly one trimmed clip, so
    /// there is nothing else to cover. `frameRate` is `exportFrameRate`'s, as `renderTransform`
    /// sampled the moving crop on.
    private func makeVideoComposition(
        in composition: AVMutableComposition,
        transform: ClipExportTransform,
        frameRate: Float,
        minFrameDuration: CMTime
    ) throws -> AVMutableVideoComposition {
        guard let compositionTrack = composition.tracks(withMediaType: .video).first else {
            throw ClipExportError.exportFailed(reason: "composition lost its video track")
        }
        do {
            return try transform.makeVideoComposition(
                for: compositionTrack, duration: composition.duration, frameRate: frameRate,
                minFrameDuration: minFrameDuration)
        } catch {
            // The grid derivation's throw stays typed: an export that cannot lay
            // out a frame grid is a failed export, not an untyped crash.
            throw ClipExportError.exportFailed(reason: "could not determine a valid frame duration")
        }
    }

    /// Runs the session to a terminal state, reporting progress along the way.
    /// `AVAssetExportSession` has no async progress stream on iOS 16, so progress is polled;
    /// task cancellation funnels into `cancelExport()`.
    private func runExport(_ session: AVAssetExportSession, progress: ProgressHandler?) async throws {
        let box = ExportSessionBox(session)
        let progressTask = Task {
            while !Task.isCancelled, !box.session.status.isTerminal {
                progress?(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Only report 1.0 on success: a failed or cancelled export never completed,
            // and the handler's contract is the fraction of this clip's export completed.
            if box.session.status == .completed {
                progress?(1.0)
            }
        }
        defer { progressTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.session.exportAsynchronously {
                    switch box.session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: ClipExportError.cancelled)
                    default:
                        continuation.resume(throwing: ClipExportError.exportFailed(
                            reason: box.session.error?.localizedDescription ?? "unknown export error"))
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }
}
