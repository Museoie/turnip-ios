import AVFoundation
import CoreGraphics
import Foundation

/// Typed failures of a processing run, surfaced by the screen's error state.
enum ProcessingError: LocalizedError {
    case assetHasNoVideoTrack

    var errorDescription: String? {
        switch self {
        case .assetHasNoVideoTrack:
            return "The selected video has no video track to analyze."
        }
    }
}

/// One progress report from a pipeline run.
struct ProcessingProgress: Equatable, Sendable {
    /// 1-based count of frames run through inference so far.
    let frame: Int
    /// Estimated from the track's duration × frame rate; nil when the track reports no frame rate.
    let totalFrames: Int?

    /// 0...1 for `ProgressView`; nil when the total is unknown, in which case the view shows
    /// an indeterminate spinner next to the frame counter.
    var fraction: Double? {
        guard let totalFrames, totalFrames > 0 else { return nil }
        return min(max(Double(frame) / Double(totalFrames), 0), 1)
    }

    /// "Analyzing frame 400 of 1,200" per `docs/UIUX.md` § "Processing". The denominator is
    /// dropped when the track reports no frame rate, and also when the count has overrun it:
    /// the estimate comes from an average frame rate, which variable-frame-rate capture beats,
    /// and "frame 412 of 400" reads as a bug where a bare counter reads as an unknown length.
    var label: String {
        guard let totalFrames, frame <= totalFrames else {
            return "Analyzing frame \(frame)…"
        }
        return "Analyzing frame \(frame) of \(totalFrames)"
    }
}

/// One detected trick ready for triage: its time window plus the crop rect the pipeline
/// computed from the window's pose keypoints (docs/DESIGN.md steps 5-6).
///
/// This is the processing screen's output contract. It deliberately mirrors — rather than
/// reuses — `ClipListItem`, whose type does not exist on `main` yet; the home flow maps each
/// clip with `ClipListItem(window: clip.window, cropRect: clip.cropRect)` when it wires the two.
struct ProcessedClip: Equatable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
}

/// The pipeline's terminal output: what the success destination needs.
struct ProcessingResult: Sendable {
    /// One clip per detected trick window, in video order.
    let clips: [ProcessedClip]
    /// The analyzed asset, for thumbnail loading downstream.
    let asset: AVURLAsset
}

/// The seam between the pipeline and frame decoding, so tests can feed canned frames without
/// a video file.
protocol FrameSampling: Sendable {
    func sampleFrames(from asset: AVURLAsset, handler: @Sendable (SampledFrame) async throws -> Void) async throws
}

extension VideoFrameSampler: FrameSampling {}

/// The seam the processing view model runs against: the real `ProcessingPipeline` in the app,
/// scripted fakes in tests.
protocol ProcessingRunning: Sendable {
    /// `onProgress` escapes: the throttled report is made from inside the sampler's handler,
    /// which outlives the call that formed the closure.
    func run(
        video: SelectedVideo,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult
}

/// Runs the full detection pipeline for the processing screen: sample frames, run pose
/// inference per frame, then collapse the pose output into trick windows with crop rects
/// (docs/DESIGN.md steps 2-6).
///
/// Takes a `SelectedVideo` rather than a `PHAsset` or a bare URL: Home already resolves the
/// picked asset — including the iCloud download and the slow-motion composition export — and
/// hands over the readable `AVURLAsset`, so PhotoKit stays out of the pipeline entirely.
///
/// Progress is per processed frame — `docs/UIUX.md` § "Processing" wants "analyzing frame
/// 400/1200", not a spinner — with the total estimated from the track's duration × frame
/// rate. Cancellation is cooperative: the sampler loop checks between frames, so cancelling
/// the run's `Task` stops the run after the in-flight frame. A `CancellationError` is never
/// wrapped — the view model must see it unwrapped to distinguish cancel from failure.
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
        video: SelectedVideo,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        let asset = video.asset
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.assetHasNoVideoTrack
        }
        // Pose keypoints are reported in the encoded frame's space (see FramePreprocessor),
        // so the crop rect is computed against the encoded pixel size, not the displayed one.
        let naturalSize = try await videoTrack.load(.naturalSize)
        let totalFrames = await Self.estimatedSampledFrames(of: videoTrack)

        let infer = try await makeInference()
        let accumulator = FrameAccumulator()
        let reportClock = ProgressReportClock()
        try await sampler.sampleFrames(from: asset) { frame in
            let keypoints = try await infer(frame)
            let processed = await accumulator.append(PoseFrameResult(
                frameIndex: frame.frameIndex,
                timestamp: frame.timestamp,
                keypoints: keypoints
            ))
            if await reportClock.shouldReport() {
                await onProgress(ProcessingProgress(frame: processed, totalFrames: totalFrames))
            }
        }

        let frames = await accumulator.frames
        let windows = windowDetector.detectWindows(in: MotionSignalBuilder.buildSignal(from: frames))
        let clips = buildClips(windows: windows, frames: frames, naturalSize: naturalSize)
        return ProcessingResult(clips: clips, asset: asset)
    }

    /// Pairs each detected window with the sampled frames inside it and computes its crop
    /// rect. A window whose frames carry no usable keypoints still becomes a clip, with a
    /// full-frame rect: the trick was detected from the motion signal, so dropping it would
    /// hide a real candidate from triage; the editor can tighten the crop.
    func buildClips(
        windows: [TrickWindow],
        frames: [PoseFrameResult],
        naturalSize: CGSize
    ) -> [ProcessedClip] {
        windows.map { window in
            let inWindow = frames.filter {
                $0.timestamp >= window.startTime && $0.timestamp <= window.endTime
            }
            let cropRect = cropRectCalculator.cropRect(for: inWindow, renderedPixelSize: naturalSize)
                ?? NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
            return ProcessedClip(window: window, cropRect: cropRect)
        }
    }

    /// Estimates how many frames the sampler will keep, for the progress denominator: the
    /// track's frame count divided by the sampler stride, rounded the way the sampler rounds —
    /// it keeps frame 0, so a 10-frame track at stride 3 yields 4 frames, not 3. Nil when the
    /// track reports no usable frame rate; the view then shows an indeterminate spinner with a
    /// counter.
    static func estimatedSampledFrames(of track: AVAssetTrack) async -> Int? {
        guard
            let timeRange = try? await track.load(.timeRange),
            timeRange.duration.isValid,
            timeRange.duration.seconds > 0,
            let frameRate = try? await track.load(.nominalFrameRate),
            frameRate > 0
        else { return nil }
        let total = Int((Float(timeRange.duration.seconds) * frameRate).rounded())
        let stride = VideoFrameSampler.stride(forNominalFrameRate: frameRate)
        return sampledFrameCount(trackFrameCount: total, stride: stride)
    }

    /// `ceil(count / stride)`, floored at 1. Requires `stride > 0`.
    static func sampledFrameCount(trackFrameCount: Int, stride: Int) -> Int {
        precondition(stride > 0, "sampledFrameCount requires stride > 0 (got \(stride))")
        return max((trackFrameCount + stride - 1) / stride, 1)
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

/// Rate-limits progress reports. Each report hops to the main actor and republishes the view
/// model's `@Published` state, which forces a SwiftUI update; a three-minute 30 fps clip
/// samples ~1,800 frames, so reporting every one of them would serialize decoding against
/// redraws no one can read.
actor ProgressReportClock {
    private let minimumInterval: TimeInterval
    private var lastReport: TimeInterval?

    init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = minimumInterval
    }

    /// True for the first call and thereafter at most once per `minimumInterval`.
    func shouldReport(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if let lastReport, now - lastReport < minimumInterval {
            return false
        }
        lastReport = now
        return true
    }
}
