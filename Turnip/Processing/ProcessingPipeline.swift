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
struct ProcessingProgress: Sendable {
    /// 1-based count of frames run through inference so far.
    let frame: Int
    /// Estimated from the track's duration × frame rate; nil when the track reports no frame rate.
    let totalFrames: Int?
    /// The just-processed frame's position in the source video and the poses it scored
    /// there — the processing screen scrubs its preview to this timestamp and draws the
    /// skeletons over it, so the video visibly tracks the progress bar rather than sitting
    /// static and paused. One skeleton when the run follows one person, everyone's when it
    /// follows everyone. Defaulted so the pipeline's own reports are the only required
    /// call site; a caller with no frame in hand (tests, the screenshot harness) gets an
    /// inert progress report instead of a compile error.
    var timestamp: TimeInterval = 0
    var skeletons: [[PoseKeypoint]] = []

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
    /// The counts are interpolated as already-rendered strings, not as `Int`s: interpolating an
    /// integer into a `String.LocalizationValue` formats it for the current locale, which turns
    /// "1200" into "1,200" — or "1.200" elsewhere — where `docs/UIUX.md` asks for "400/1200" and
    /// `ClipDurationFormatter` makes the same call about its own separator.
    var label: String {
        guard let totalFrames, frame <= totalFrames else {
            return String(localized: "Analyzing frame \(String(frame))…")
        }
        return String(localized: "Analyzing frame \(String(frame)) of \(String(totalFrames))")
    }
}

/// One detected trick ready for triage: its time window plus the crop rect the pipeline
/// computed from the window's pose keypoints (docs/DESIGN.md steps 5-6).
///
/// This is the processing screen's output contract. It deliberately mirrors — rather than
/// reuses — `ClipListItem` (Turnip/ClipList/ClipListItem.swift): a screen's output contract
/// should not be its neighbour's view model, so the home flow maps each clip with
/// `ClipListItem(window: clip.window, cropRect: clip.cropRect, personID: clip.personID)` when it
/// wires the two.
struct ProcessedClip: Hashable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
    /// Whose trick this is, a `PoseTrack.id` in `DetectedClips.people`, when the run followed
    /// everyone; `nil` when it followed one person.
    var personID: Int?
}

/// What detection yields for one video: the clips, with every sampled frame they were cut
/// from. The frames travel with the clips because the editor needs frames beyond a clip's
/// own window — Auto crop frames whatever keypoints the trimmed window holds, and a trim
/// handle dragged outward pulls in frames the clip didn't start with — and both the file
/// pipeline and the camera's live scoring are sources of them.
struct DetectedClips: Hashable, Sendable {
    /// One clip per detected trick window, in video order.
    let clips: [ProcessedClip]
    /// Every scored frame of the video, in video order, in the display-orientation
    /// normalized space the clips' crop rects were computed in: the pose of the person the
    /// model was surest of in each. What a clip without a person reads.
    let poseFrames: [PoseFrameResult]
    /// The people whose tricks became clips, when the run followed everyone. Only those: the
    /// detection rides in the navigation path and is hashed on every push.
    var people: [PoseTrack] = []

    /// The frames a clip's crop, follow path and the editor's Auto crop read: its own person's
    /// when it has one, every scored frame otherwise.
    func poseFrames(forPerson personID: Int?) -> [PoseFrameResult] {
        personID.flatMap { id in people.first { $0.id == id }?.frames } ?? poseFrames
    }
}

/// The pipeline's terminal output: what the success destination needs.
struct ProcessingResult: Sendable {
    let detection: DetectedClips
    /// The analyzed asset, for thumbnail loading downstream.
    let asset: AVURLAsset
    /// `true` when the user went straight to the clip list from Processing's idle state
    /// without running the pipeline (`ProcessingViewModel.skipAnalysis`). The detection is
    /// then empty by construction, not by finding nothing, so the clip list must not put up
    /// its "No tricks found" notice over it — that is the one thing a consumer can't tell
    /// from an empty `detection` alone.
    var analysisSkipped = false

    var clips: [ProcessedClip] { detection.clips }
}

/// The seam between the pipeline and frame decoding, so tests can feed canned frames without
/// a video file.
protocol FrameSampling: Sendable {
    func sampleFrames(from asset: AVURLAsset, handler: @Sendable (SampledFrame) async throws -> Void) async throws
    /// One frame per wanted time — the first at or after it — rather than a whole-take sweep.
    func sampleFrames(
        from asset: AVURLAsset, at times: [TimeInterval],
        handler: @Sendable (SampledFrame) async throws -> Void
    ) async throws
}

extension VideoFrameSampler: FrameSampling {}

/// The seam the processing view model runs against: the real `ProcessingPipeline` in the app,
/// scripted fakes in tests.
protocol ProcessingRunning: Sendable {
    /// `people` is read when the user starts the run, not when the screen was built: the screen
    /// carries its own choice of mode. `onProgress` escapes: the throttled report is made from
    /// inside the sampler's handler, which outlives the call that formed the closure.
    func run(
        video: SelectedVideo,
        people: PersonMode,
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
    /// rather than per frame. The default loads the bundled MoveNet MultiPose model; tests
    /// inject a stub.
    typealias InferenceFactory = @Sendable () async throws -> @Sendable (SampledFrame) async throws -> [DetectedPerson]

    let sampler: any FrameSampling
    /// Samples per second of footage this run targets — `TurnipSettings.analysisGranularity`
    /// when a caller reads settings, `VideoFrameSampler.targetSamplesPerSecond` otherwise. Drives
    /// both the default `sampler` (when the caller doesn't supply its own) and the progress
    /// denominator in `estimatedSampledFrames`, so the two agree on one rate. Detection needs no
    /// rate: its signal is a speed and its thresholds are durations.
    let sampleRate: Int
    let makeInference: InferenceFactory
    let cropRectCalculator: CropRectCalculator
    let windowDetector: TrickWindowDetector
    let personTracker = PersonTracker()

    init(
        sampler: (any FrameSampling)? = nil,
        sampleRate: Int = VideoFrameSampler.targetSamplesPerSecond,
        makeInference: @escaping InferenceFactory = ProcessingPipeline.defaultInference,
        cropRectCalculator: CropRectCalculator = CropRectCalculator(),
        windowDetector: TrickWindowDetector? = nil
    ) {
        self.sampler = sampler ?? VideoFrameSampler(sampleRate: sampleRate)
        self.sampleRate = sampleRate
        self.makeInference = makeInference
        self.cropRectCalculator = cropRectCalculator
        self.windowDetector = windowDetector ?? TrickWindowDetector()
    }

    /// Loads the bundled MoveNet MultiPose model once, then answers each frame with everyone it
    /// found.
    private static let defaultInference: InferenceFactory = {
        let model = try await MoveNetMultiPoseModel.load()
        return { frame in try await model.runInference(on: frame.pixelBuffer) }
    }

    func run(
        video: SelectedVideo,
        people mode: PersonMode = .one,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        let asset = video.asset
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.assetHasNoVideoTrack
        }
        if let partial = video.partialPose {
            return try await backfill(partial, of: asset, people: mode, onProgress: onProgress)
        }
        let totalFrames = await Self.estimatedSampledFrames(of: videoTrack, sampleRate: sampleRate)

        let infer = try await makeInference()
        let accumulator = FrameAccumulator()
        let reportClock = ProgressReportClock()
        try await sampler.sampleFrames(from: asset) { frame in
            let scored = MultiPoseFrame(
                frameIndex: frame.frameIndex, timestamp: frame.timestamp, people: try await infer(frame))
            let processed = await accumulator.append(scored, renderSize: frame.renderSize)
            if await reportClock.shouldReport() {
                await onProgress(ProcessingProgress(
                    frame: processed, totalFrames: totalFrames,
                    timestamp: frame.timestamp, skeletons: mode.skeletons(in: scored)))
            }
        }

        let frames = await accumulator.frames
        // Pose keypoints are measured in the composition's display-orientation space (see
        // SampledFrame.renderSize), so the crop rect is computed against the frames' renderSize,
        // not the track's encoded naturalSize: on a rotated (portrait phone) clip naturalSize
        // transposes the dimensions and the aspect-ratio snap lands on a wrongly-proportioned
        // rect. No sampled frames means no keypoints, so the size is unused there —
        // `.zero` marks it unknown, which the calculator treats as unlocatable and buildClips
        // turns into the full-frame fallback.
        let renderedPixelSize = await accumulator.renderSize ?? .zero
        return ProcessingResult(
            detection: detect(in: frames, people: mode, renderedPixelSize: renderedPixelSize), asset: asset)
    }

    /// A take the camera scored live in part: scores only the times `PoseBackfill` plans for the
    /// stretches the live frames miss, at the live pass's own spacing rather than `sampleRate`,
    /// and detects over the two merged. Live frames past the end of the file are dropped first:
    /// the camera keeps scoring between Stop and its own hand-off. Progress counts the live
    /// frames as already processed, so the bar starts where live inference left off.
    private func backfill(
        _ partial: PartialPoseFrames, of asset: AVURLAsset, people mode: PersonMode,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        let duration = try await asset.load(.duration).seconds
        let live = partial.frames.filter { $0.timestamp < duration }
        let wanted = PoseBackfill.wantedTimes(
            scored: live.map(\.timestamp), interval: partial.interval, duration: duration)

        let accumulator = FrameAccumulator()
        if !wanted.isEmpty {
            let infer = try await makeInference()
            let reportClock = ProgressReportClock()
            let totalFrames = live.count + wanted.count
            try await sampler.sampleFrames(from: asset, at: wanted) { frame in
                let scored = MultiPoseFrame(
                    frameIndex: frame.frameIndex, timestamp: frame.timestamp, people: try await infer(frame))
                let processed = await accumulator.append(scored, renderSize: frame.renderSize)
                if await reportClock.shouldReport() {
                    await onProgress(ProcessingProgress(
                        frame: live.count + processed, totalFrames: totalFrames,
                        timestamp: frame.timestamp, skeletons: mode.skeletons(in: scored)))
                }
            }
        }

        let frames = PoseBackfill.merged(
            live: live, backfilled: await accumulator.frames, interval: partial.interval)
        // The file's composition size when any frame came from the file, as `run` uses; the
        // live pass's own measure of the same picture otherwise.
        let renderedPixelSize = await accumulator.renderSize ?? partial.renderedPixelSize
        return ProcessingResult(
            detection: detect(in: frames, people: mode, renderedPixelSize: renderedPixelSize), asset: asset)
    }

    /// Steps 4-6 for a take whose frames hold everyone the model found. Following one person,
    /// they run once over the person the model was surest of in each frame. Following everyone,
    /// the people are tracked across the take (`PersonTracker`) and they run once per person, so
    /// each person's speed is measured against their own activity and each clip frames its own
    /// person. Both frame sources call this: the file sampler above and the camera's hand-off.
    func detect(in frames: [MultiPoseFrame], people mode: PersonMode, renderedPixelSize: CGSize) -> DetectedClips {
        let primary = frames.map(\.primary)
        guard mode == .everyone else {
            return DetectedClips(
                clips: detectClips(in: primary, renderedPixelSize: renderedPixelSize), poseFrames: primary)
        }
        var clips: [ProcessedClip] = []
        var people: [PoseTrack] = []
        for track in personTracker.tracks(in: frames, renderedPixelSize: renderedPixelSize) {
            let found = detectClips(in: track.frames, renderedPixelSize: renderedPixelSize)
            guard !found.isEmpty else { continue }
            people.append(track)
            clips += found.map { ProcessedClip(window: $0.window, cropRect: $0.cropRect, personID: track.id) }
        }
        clips.sort { ($0.window.startTime, $0.personID ?? -1) < ($1.window.startTime, $1.personID ?? -1) }
        return DetectedClips(clips: clips, poseFrames: primary, people: people)
    }

    /// Steps 4-6 over frames that have already been scored: motion signal, trick windows, crop
    /// rects. The one detection implementation for both frame sources — the file sampler above
    /// and the camera's live inference, whose results arrive in the same frame-normalized,
    /// display-orientation space with file-relative timestamps at the same sample rate.
    func detectClips(in frames: [PoseFrameResult], renderedPixelSize: CGSize) -> [ProcessedClip] {
        let windows = windowDetector.detectWindows(
            in: MotionSignalBuilder.buildSignal(from: frames, renderedPixelSize: renderedPixelSize))
        return buildClips(windows: windows, frames: frames, renderedPixelSize: renderedPixelSize)
    }

    /// Pairs each detected window with the sampled frames inside it and computes its crop
    /// rect. A window whose frames carry no usable keypoints still becomes a clip, with a
    /// full-frame rect: the trick was detected from the motion signal, so dropping it would
    /// hide a real candidate from triage; the editor can tighten the crop.
    func buildClips(
        windows: [TrickWindow],
        frames: [PoseFrameResult],
        renderedPixelSize: CGSize
    ) -> [ProcessedClip] {
        windows.map { window in
            let inWindow = frames.filter {
                $0.timestamp >= window.startTime && $0.timestamp <= window.endTime
            }
            let cropRect = cropRectCalculator.cropRect(
                for: inWindow, renderedPixelSize: renderedPixelSize)
                ?? NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
            return ProcessedClip(window: window, cropRect: cropRect)
        }
    }

    /// Estimates how many frames the sampler will keep, for the progress denominator: the
    /// track's frame count divided by the sampler stride, rounded the way the sampler rounds —
    /// it keeps frame 0, so a 10-frame track at stride 3 yields 4 frames, not 3. Nil when the
    /// track reports no usable frame rate; the view then shows an indeterminate spinner with a
    /// counter.
    static func estimatedSampledFrames(
        of track: AVAssetTrack, sampleRate: Int = VideoFrameSampler.targetSamplesPerSecond
    ) async -> Int? {
        guard
            let timeRange = try? await track.load(.timeRange),
            timeRange.duration.isValid,
            timeRange.duration.seconds > 0,
            let frameRate = try? await track.load(.nominalFrameRate),
            frameRate > 0
        else { return nil }
        let total = Int((Float(timeRange.duration.seconds) * frameRate).rounded())
        let stride = VideoFrameSampler.stride(forNominalFrameRate: frameRate, sampleRate: sampleRate)
        return sampledFrameCount(trackFrameCount: total, stride: stride)
    }

    /// `ceil(count / stride)`, floored at 1. Requires `stride > 0`.
    static func sampledFrameCount(trackFrameCount: Int, stride: Int) -> Int {
        precondition(stride > 0, "sampledFrameCount requires stride > 0 (got \(stride))")
        return max((trackFrameCount + stride - 1) / stride, 1)
    }
}

extension ProcessingPipeline: ProcessingRunning {}

extension PersonMode {
    /// What a progress overlay draws for one frame: the followed person's skeleton, or everyone's.
    func skeletons(in frame: MultiPoseFrame) -> [[PoseKeypoint]] {
        switch self {
        case .one:
            return frame.primary.keypoints.isEmpty ? [] : [frame.primary.keypoints]
        case .everyone:
            return frame.people.map(\.keypoints)
        }
    }
}

/// Collects the handler's per-frame results. The sampler's handler is `@Sendable` and runs
/// off the main actor, so the accumulation point is an actor rather than a captured `var`.
private actor FrameAccumulator {
    private(set) var frames: [MultiPoseFrame] = []
    /// The composition grid the run's frames were rendered onto, in display orientation. The
    /// sampler builds one composition per run, so the first frame's size stands for all of
    /// them; pose keypoints are measured in this space, so the crop math denormalizes against
    /// it rather than the track's encoded `naturalSize`. Nil when the sampler
    /// produced no frame.
    private(set) var renderSize: CGSize?

    /// Appends the frame's inference result and returns the 1-based processed count for
    /// progress reporting. Records the run's render size from the first frame.
    func append(_ result: MultiPoseFrame, renderSize: CGSize) -> Int {
        if self.renderSize == nil {
            self.renderSize = renderSize
        }
        frames.append(result)
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
