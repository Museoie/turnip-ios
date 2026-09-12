import AVFoundation
import CoreGraphics
import Foundation

/// One detected clip to export: its time window in the source video and the static crop rect
/// for it (docs/DESIGN.md's pipeline steps 5-6 feeding step 7).
struct ClipSpec: Equatable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
}

/// A successfully exported clip.
struct ExportedClip: Sendable {
    let spec: ClipSpec
    let fileURL: URL
}

/// Failures a clip export can hit, typed so callers can tell a bad window (skip the clip)
/// from an export-session failure (retryable) without parsing strings.
enum ClipExportError: Error, Equatable {
    case noVideoTrack
    case invalidTimeRange(window: TrickWindow)
    case invalidCropRect(window: TrickWindow)
    case exportFailed(reason: String)
    case cancelled
}

/// The render geometry for one exported clip, computed from pure inputs — no AVFoundation
/// session required, so it is unit-testable.
struct ClipExportTransform {
    /// Output frame size in pixels.
    let renderSize: CGSize
    /// Maps the source video track's coordinates onto the composition's render space.
    let layerTransform: CGAffineTransform

    /// Builds the crop transform for `cropRect`.
    ///
    /// `cropRect` lives in the encoded frame's pixel space (top-left origin) — the same space
    /// as the pose keypoints it is computed from, since the frame sampler does not apply the
    /// track's `preferredTransform`. The layer transform therefore starts from
    /// `preferredTransform` (so the export comes out upright) and translates the crop's
    /// displayed top-left corner to the origin. There is no Y-flip: an
    /// `AVMutableVideoCompositionLayerInstruction` transform maps into a top-left-origin
    /// render space, the same space `preferredTransform` already targets — the bottom-left
    /// convention belongs to Core Image and to `AVVideoCompositionCoreAnimationTool`
    /// overlay layers, neither of which is in play here. The crop is never scaled: the
    /// output frame is exactly the crop rect's size, rounded up to even H.264 dimensions,
    /// per the design doc's "crop, not scale-and-letterbox".
    ///
    /// `nil` when the source dimensions are unknown or the crop rect is degenerate — in
    /// either case there is no frame to render into.
    static func make(
        cropRect: NormalizedRect,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> ClipExportTransform? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        let crop = cropRect.denormalized(in: naturalSize)
        guard crop.width > 0, crop.height > 0 else { return nil }

        // The crop's corners run through preferredTransform to find where the crop sits in
        // the displayed (upright) frame. The origin must be subtracted in *displayed* space:
        // for a 90°-rotated track the encoded top-left corner lands at the displayed
        // top-right, so subtracting the encoded origin would shift the crop to the wrong side.
        let displayed = boundingBox(of: crop.corners.map { $0.applying(preferredTransform) })

        let layerTransform = preferredTransform
            .concatenating(CGAffineTransform(translationX: -displayed.minX, y: -displayed.minY))

        // H.264 requires integral, even width and height, and the crop math above is
        // float — round here. The layer transform already pins the crop's displayed
        // top-left to the render origin, so widening the frame only pads the
        // right/bottom edges; the translation stays consistent with the rounded size.
        let renderSize = CGSize(
            width: displayed.width.roundedToEvenDimensions,
            height: displayed.height.roundedToEvenDimensions)

        return ClipExportTransform(renderSize: renderSize, layerTransform: layerTransform)
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
        let xValues = points.map(\.x), yValues = points.map(\.y)
        guard let minX = xValues.min(), let maxX = xValues.max(),
              let minY = yValues.min(), let maxY = yValues.max()
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
/// thread. The exporter is UI-independent: it takes clip specs and returns file URLs, and a
/// preview screen or a test calls it the same way. Writing the files to Photos is
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
        guard let transform = ClipExportTransform.make(
            cropRect: spec.cropRect, naturalSize: naturalSize, preferredTransform: preferredTransform
        ) else {
            throw ClipExportError.invalidCropRect(window: spec.window)
        }

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        // The ranges are computed here, where spec.window is in hand, so an empty video
        // range reports invalidTimeRange (a deterministic bad window) instead of the
        // retryable exportFailed that a window-less makeComposition had to throw.
        let videoTrackRange = try await videoTrack.load(.timeRange)
        let audioTrackRange = try await audioTrack?.load(.timeRange)
        guard let ranges = Self.insertRanges(
            trim: timeRange, videoTrack: videoTrackRange, audioTrack: audioTrackRange)
        else {
            throw ClipExportError.invalidTimeRange(window: spec.window)
        }
        let composition = try makeComposition(
            videoTrack: videoTrack, audioTrack: audioTrack, ranges: ranges)
        let videoComposition = try await makeVideoComposition(
            for: videoTrack, in: composition, transform: transform)

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
        return ExportedClip(spec: spec, fileURL: outputURL)
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
    /// transform at time zero. The instruction's range is the composition's full duration —
    /// the composition holds exactly one trimmed clip, so there is nothing else to cover.
    private func makeVideoComposition(
        for videoTrack: AVAssetTrack,
        in composition: AVMutableComposition,
        transform: ClipExportTransform
    ) async throws -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = transform.renderSize
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        // nominalFrameRate is 0 on assets that don't report one; fall back to 30 rather
        // than a 1 fps timescale so the render clock stays sane.
        let timescale = frameRate > 0 ? Int32(frameRate.rounded()) : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        guard let compositionTrack = composition.tracks(withMediaType: .video).first else {
            throw ClipExportError.exportFailed(reason: "composition lost its video track")
        }
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(transform.layerTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        return videoComposition
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

    /// Exports every clip, collecting a per-clip `Result` so one bad window doesn't abort the
    /// rest — multi-trick recordings routinely produce a window the trimmer has to reject.
    /// Results come back in the same order as `specs`. If the task is cancelled, the
    /// in-flight clip records `.cancelled` and the remaining clips are skipped:
    /// cancellation stops the batch instead of failing every clip after it.
    func export(
        _ specs: [ClipSpec],
        from asset: AVAsset,
        to directory: URL,
        progress: (@Sendable (Int, Double) -> Void)? = nil
    ) async -> [Result<ExportedClip, Error>] {
        var results: [Result<ExportedClip, Error>] = []
        for (index, spec) in specs.enumerated() {
            // Cancellation is not a bad window — stop instead of recording a failure
            // per remaining clip.
            guard !Task.isCancelled else { break }
            do {
                let clip = try await export(spec, from: asset, to: directory) { fraction in
                    progress?(index, fraction)
                }
                results.append(.success(clip))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }
}
