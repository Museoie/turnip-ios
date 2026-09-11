import AVFoundation
import CoreGraphics
import Foundation
import Photos

/// Typed failures of a processing run (issue #17's error state).
enum ProcessingError: LocalizedError {
    case assetHasNoVideoTrack
    case photoAssetUnavailable(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .assetHasNoVideoTrack:
            return "The selected video has no video track to analyze."
        case .photoAssetUnavailable(let underlying):
            if let underlying {
                return "The selected photo-library video couldn't be loaded: "
                    + underlying.localizedDescription
            }
            return "The selected photo-library video couldn't be loaded."
        }
    }
}

/// One progress report from a pipeline run, in run order: an optional iCloud-download phase
/// first, then per-frame processing progress.
enum ProcessingProgress: Equatable, Sendable {
    /// 0...1 fraction of the iCloud download (photo-asset inputs only).
    case downloading(Double)
    /// `frame` is the 1-based count of frames run through inference so far; `totalFrames` is
    /// estimated from duration × frame rate and is nil when the track reports no frame rate.
    case processing(frame: Int, totalFrames: Int?)

    /// 0...1 for `ProgressView`; nil when the total is unknown, in which case the view shows
    /// an indeterminate spinner next to the frame counter.
    var fraction: Double? {
        switch self {
        case .downloading(let fraction):
            return min(max(fraction, 0), 1)
        case .processing(let frame, let totalFrames):
            guard let totalFrames, totalFrames > 0 else { return nil }
            return min(max(Double(frame) / Double(totalFrames), 0), 1)
        }
    }
}

/// One detected trick ready for triage: its time window plus the crop rect the pipeline
/// computed from the window's pose keypoints (docs/DESIGN.md steps 5-6).
///
/// This is the processing screen's output contract. It deliberately mirrors — rather than
/// reuses — `ClipListItem`: the clip list (#11) is still an unmerged PR, so this screen can't
/// depend on its type; the home flow maps each clip with
/// `ClipListItem(window: clip.window, cropRect: clip.cropRect)` when it wires the two.
struct ProcessedClip: Equatable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
}

/// The pipeline's terminal output: what the success destination (the clip list, #11) needs.
///
/// `AVAsset` is not `Sendable`; this is `@unchecked Sendable` because the pipeline only
/// reads the asset through its async `load(_:)` API, which AVFoundation documents as safe
/// to call from any thread, and hands it on for main-actor thumbnail loading downstream.
struct ProcessingResult: @unchecked Sendable {
    /// One clip per detected trick window, in video order.
    let clips: [ProcessedClip]
    /// The resolved asset, for thumbnail loading downstream.
    let asset: AVAsset
}

/// The seam between the pipeline and frame decoding, so tests can feed canned frames without
/// a video file.
protocol FrameSampling: Sendable {
    func sampleFrames(from url: URL, handler: @Sendable (SampledFrame) async throws -> Void) async throws
}

extension VideoFrameSampler: FrameSampling {}

/// The seam the processing view model runs against: the real `ProcessingPipeline` in the app,
/// scripted fakes in tests.
protocol ProcessingRunning: Sendable {
    /// `onProgress` escapes: it is captured by the iCloud download's progress handler and
    /// by a `Task` inside `requestFileBackedAsset`, so the closure must be `@escaping`.
    func run(
        input: ProcessingInput,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult
}

/// Runs the full detection pipeline for the processing screen (issue #17): resolve the input
/// to a file-backed asset (downloading iCloud-only photo assets first), sample frames,
/// run pose inference per frame, then collapse the pose output into trick windows with crop
/// rects (docs/DESIGN.md steps 2-6).
///
/// Progress is per processed frame — `docs/UIUX.md` § "Processing" wants "analyzing frame
/// 400/1200", not a spinner — with the total estimated from the track's duration × frame
/// rate. Cancellation is cooperative: the sampler loop checks between frames, so cancelling
/// the run's `Task` stops the run after the in-flight frame (full preemption hooks land with
/// #21). A `CancellationError` is never wrapped — the view model must see it unwrapped to
/// distinguish cancel from failure.
struct ProcessingPipeline: Sendable {
    /// Builds the per-frame inference function once per run, so the model loads a single time
    /// rather than per frame. The default loads the bundled MoveNet Thunder model; tests
    /// inject a stub.
    typealias InferenceFactory = @Sendable () async throws -> @Sendable (SampledFrame) async throws -> [PoseKeypoint]

    let sampler: any FrameSampling
    let makeInference: InferenceFactory
    let cropRectCalculator: CropRectCalculator
    let windowDetector: TrickWindowDetector

    init(
        sampler: any FrameSampling = VideoFrameSampler(),
        makeInference: @escaping InferenceFactory = ProcessingPipeline.defaultInference,
        cropRectCalculator: CropRectCalculator = CropRectCalculator(),
        windowDetector: TrickWindowDetector = TrickWindowDetector()
    ) {
        self.sampler = sampler
        self.makeInference = makeInference
        self.cropRectCalculator = cropRectCalculator
        self.windowDetector = windowDetector
    }

    /// Loads the bundled MoveNet Thunder model once, then answers each frame from it.
    private static let defaultInference: InferenceFactory = {
        let model = try await MoveNetThunderModel.load()
        return { frame in try await model.runInference(on: frame.pixelBuffer) }
    }

    func run(
        input: ProcessingInput,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        let (asset, fileURL) = try await Self.resolveAsset(from: input, onProgress: onProgress)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.assetHasNoVideoTrack
        }
        // Pose keypoints are reported in the encoded frame's space (see FramePreprocessor),
        // so the crop rect is computed against the encoded pixel size, not the displayed one.
        let naturalSize = try await videoTrack.load(.naturalSize)
        let totalFrames = await Self.estimatedSampledFrames(of: videoTrack)

        let infer = try await makeInference()
        let accumulator = FrameAccumulator()
        try await sampler.sampleFrames(from: fileURL) { frame in
            let keypoints = try await infer(frame)
            let processed = await accumulator.append(PoseFrameResult(
                frameIndex: frame.frameIndex,
                timestamp: frame.timestamp,
                keypoints: keypoints
            ))
            await onProgress(.processing(frame: processed, totalFrames: totalFrames))
        }

        let frames = await accumulator.frames
        let windows = windowDetector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))
        let clips = buildClips(windows: windows, frames: frames, naturalSize: naturalSize)
        return ProcessingResult(clips: clips, asset: asset)
    }

    /// Pairs each detected window with the sampled frames inside it and computes its crop
    /// rect. A window whose frames carry no usable keypoints still becomes a clip, with a
    /// full-frame rect: the trick was detected from the motion signal, so dropping it would
    /// hide a real candidate from triage; the editor (#18) can tighten the crop.
    func buildClips(
        windows: [TrickWindow],
        frames: [PoseFrameResult],
        naturalSize: CGSize
    ) -> [ProcessedClip] {
        windows.map { window in
            let inWindow = frames.filter {
                $0.timestamp >= window.startTime && $0.timestamp <= window.endTime
            }
            let cropRect = cropRectCalculator.cropRect(for: inWindow, sourcePixelSize: naturalSize)
                ?? NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
            return ProcessedClip(window: window, cropRect: cropRect)
        }
    }

    private static func resolveAsset(
        from input: ProcessingInput,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> (asset: AVAsset, fileURL: URL) {
        switch input.source {
        case .fileURL(let url):
            return (AVURLAsset(url: url), url)
        case .photoAsset(let photoAsset):
            return try await requestFileBackedAsset(for: photoAsset, onProgress: onProgress)
        }
    }

    /// Resolves a photo-library asset to a file-backed `AVURLAsset`, downloading iCloud-only
    /// originals first and reporting that download as pipeline progress. Cancellation while
    /// the download is in flight is best-effort — `withCheckedThrowingContinuation` can't
    /// observe it — which the issue accepts as the stub until #21 lands.
    private static func requestFileBackedAsset(
        for photoAsset: PHAsset,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> (asset: AVAsset, fileURL: URL) {
        // Explicit continuation type: the labelled tuple is ambiguous to the compiler
        // without it (the resumed tuple carries an `AVURLAsset` where `AVAsset` is wanted).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(asset: AVAsset, fileURL: URL), Error>) in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.progressHandler = { fraction, _ in
                // Arbitrary queue, no shared state — a detached Task is safe here.
                Task { await onProgress(.downloading(fraction)) }
            }
            PHImageManager.default().requestAVAsset(forVideo: photoAsset, options: options) {
                avAsset, _, info in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(throwing: ProcessingError.photoAssetUnavailable(
                        underlying: info?[PHImageErrorKey] as? Error
                    ))
                    return
                }
                continuation.resume(returning: (urlAsset, urlAsset.url))
            }
        }
    }

    /// Estimates how many frames the sampler will keep, for the progress denominator: the
    /// track's frame count divided by the sampler stride. Nil when the track reports no
    /// usable frame rate — the view then shows an indeterminate spinner with a counter.
    private static func estimatedSampledFrames(of track: AVAssetTrack) async -> Int? {
        guard
            let timeRange = try? await track.load(.timeRange),
            timeRange.duration.isValid,
            timeRange.duration.seconds > 0,
            let frameRate = try? await track.load(.nominalFrameRate),
            frameRate > 0
        else { return nil }
        let total = Int((Float(timeRange.duration.seconds) * frameRate).rounded())
        return max(total / VideoFrameSampler.sampleStride, 1)
    }
}

extension ProcessingPipeline: ProcessingRunning {}

/// Collects the handler's per-frame results. The sampler's handler is `@Sendable` and runs
/// off the main actor, so the accumulation point is an actor rather than a captured `var`.
private actor FrameAccumulator {
    private(set) var frames: [PoseFrameResult] = []

    /// Appends the frame and returns the 1-based processed count for progress reporting.
    func append(_ frame: PoseFrameResult) -> Int {
        frames.append(frame)
        return frames.count
    }
}
