import AVFoundation
import CoreGraphics
import Foundation
import os

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
/// should not be its neighbour's view model, so the home flow maps each clip to a
/// `ClipListItem` when it wires the two.
struct ProcessedClip: Hashable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
    /// Whose trick this is, a `PoseTrack.id` in `DetectedClips.people`, when the run followed
    /// everyone; `nil` when it followed one person.
    var personID: Int?
    /// How the trick model proposed the clip, with the names it starts with; `nil` when the
    /// heuristic found it.
    var proposal: ModelProposal?
}

/// What detection yields for one video: the clips, with every sampled frame they were cut
/// from. The frames travel with the clips because the editor needs frames beyond a clip's
/// own window — Auto follow frames whatever keypoints the trimmed window holds, and a trim
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
    /// The trick model's embeddings over each pose it proposed clips from: the one person's, or
    /// each of `people`'s. Empty when the heuristic proposed.
    var windowEmbeddings: [WindowEmbeddings] = []

    /// The frames a clip's crop, follow path and the editor's Auto follow read: its own person's
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
    /// The trick model a run proposes clips with, or `nil` for the heuristic: none is staged, or
    /// it failed to load. The default is the app's one shared loader.
    typealias TrickModelFactory = @Sendable () async -> TrickModel?

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
    let loadTrickModel: TrickModelFactory
    let proposalRules: TrickProposalRules
    let personTracker = PersonTracker()
    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "TrickModel")

    init(
        sampler: (any FrameSampling)? = nil,
        sampleRate: Int = VideoFrameSampler.targetSamplesPerSecond,
        makeInference: @escaping InferenceFactory = ProcessingPipeline.defaultInference,
        cropRectCalculator: CropRectCalculator = CropRectCalculator(),
        windowDetector: TrickWindowDetector? = nil,
        loadTrickModel: @escaping TrickModelFactory = { await TrickModelLoader.shared.model() },
        proposalRules: TrickProposalRules = TrickProposalRules()
    ) {
        self.sampler = sampler ?? VideoFrameSampler(sampleRate: sampleRate)
        self.sampleRate = sampleRate
        self.makeInference = makeInference
        self.cropRectCalculator = cropRectCalculator
        self.windowDetector = windowDetector ?? TrickWindowDetector()
        self.loadTrickModel = loadTrickModel
        self.proposalRules = proposalRules
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
        // The scored frames stream to a disk-backed store, not an array: a long take's
        // frames would otherwise sit in memory twice over — once here, once in the result.
        // The store holds 64 KB in memory; the detection pass re-reads it from disk.
        let store = PoseFrameStore()
        defer { store.discard() }
        let firstRenderSize = FirstRenderSize()
        let reportClock = ProgressReportClock()
        try await sampler.sampleFrames(from: asset) { frame in
            let scored = MultiPoseFrame(
                frameIndex: frame.frameIndex, timestamp: frame.timestamp, people: try await infer(frame))
            try store.append(scored)
            await firstRenderSize.set(frame.renderSize)
            if await reportClock.shouldReport() {
                await onProgress(ProcessingProgress(
                    frame: store.count, totalFrames: totalFrames,
                    timestamp: frame.timestamp, skeletons: mode.skeletons(in: scored)))
            }
        }
        try store.flush()

        // Pose keypoints are measured in the composition's display-orientation space (see
        // SampledFrame.renderSize), so the crop rect is computed against the frames' renderSize,
        // not the track's encoded naturalSize: on a rotated (portrait phone) clip naturalSize
        // transposes the dimensions and the aspect-ratio snap lands on a wrongly-proportioned
        // rect. No sampled frames means no keypoints, so the size is unused there —
        // `.zero` marks it unknown, which the calculator treats as unlocatable and buildClips
        // turns into the full-frame fallback.
        let renderedPixelSize = await firstRenderSize.value ?? .zero
        // The asset's duration, loaded here so the detected windows are
        // clamped before they reach triage: without it the trailing buffer
        // lets the last window run past the file, and the card labels a
        // longer clip than the export produces.
        let duration = try await asset.load(.duration).seconds
        return ProcessingResult(
            detection: detectStreaming(
                frames: { store.frames() }, people: mode, renderedPixelSize: renderedPixelSize,
                duration: duration, trickModel: await loadTrickModel()),
            asset: asset)
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
        // An unreadable store (the system may purge `tmp/` while the app is suspended) reads as
        // no live frames: the whole file is sampled instead of failing the run. Only the
        // timestamps are collected — the live frames themselves stream from the store at
        // detection, so the live take never sits in memory as an array.
        let liveTimes = partial.store.frames().map(\.timestamp).filter { $0 < duration }
        let wanted = PoseBackfill.wantedTimes(
            scored: liveTimes, interval: partial.interval, duration: duration)

        // The gaps are sampled into a fresh store, and detection streams the live and
        // backfilled stores merged by timestamp — neither take sits in memory as an array.
        let store = PoseFrameStore()
        defer { store.discard() }
        let firstRenderSize = FirstRenderSize()
        if !wanted.isEmpty {
            let infer = try await makeInference()
            let reportClock = ProgressReportClock()
            let totalFrames = liveTimes.count + wanted.count
            try await sampler.sampleFrames(from: asset, at: wanted) { frame in
                let scored = MultiPoseFrame(
                    frameIndex: frame.frameIndex, timestamp: frame.timestamp, people: try await infer(frame))
                try store.append(scored)
                await firstRenderSize.set(frame.renderSize)
                if await reportClock.shouldReport() {
                    await onProgress(ProcessingProgress(
                        frame: liveTimes.count + store.count, totalFrames: totalFrames,
                        timestamp: frame.timestamp, skeletons: mode.skeletons(in: scored)))
                }
            }
            try store.flush()
        }

        let frames = MergedPoseFrames(
            live: partial.store, backfilled: store, interval: partial.interval, duration: duration)
        // The file's composition size when any frame came from the file, as `run` uses; the
        // live pass's own measure of the same picture otherwise.
        let renderedPixelSize = await firstRenderSize.value ?? partial.renderedPixelSize
        return ProcessingResult(
            detection: detectStreaming(
                frames: { AnySequence(frames) }, people: mode, renderedPixelSize: renderedPixelSize,
                duration: duration, trickModel: await loadTrickModel()),
            asset: asset)
    }

    /// Steps 4-6 for a take whose frames hold everyone the model found. Following one person,
    /// they run once over the person the model was surest of in each frame. Following everyone,
    /// the people are tracked across the take (`PersonTracker`) and they run once per person, so
    /// each person's speed is measured against their own activity and each clip frames its own
    /// person. Both frame sources call this: the file sampler above and the camera's hand-off.
    /// `duration` is the asset's length in seconds when the caller knows it
    /// (the file runs); `nil` for the camera's live inference, where no file
    /// exists yet and the windows reach triage unclamped. A non-nil duration
    /// clamps every window at the pipeline boundary, so the triage card, the
    /// export confirmation row, and the exported file all read the same
    /// window instead of the card labelling up to the trailing buffer past
    /// the clip that actually exports.
    /// With a `trickModel`, it proposes the clips, run once over each pose; without one, the
    /// heuristic does.
    func detect(
        in frames: [MultiPoseFrame], people mode: PersonMode, renderedPixelSize: CGSize,
        duration: TimeInterval? = nil, trickModel: TrickModel? = nil
    ) -> DetectedClips {
        let primary = frames.map(\.primary)
        guard mode == .everyone else {
            let found = proposeClips(
                in: primary, personID: nil, renderedPixelSize: renderedPixelSize, duration: duration,
                trickModel: trickModel)
            return DetectedClips(
                clips: found.clips, poseFrames: primary, windowEmbeddings: found.embeddings.map { [$0] } ?? [])
        }
        var clips: [ProcessedClip] = []
        var people: [PoseTrack] = []
        var embeddings: [WindowEmbeddings] = []
        for track in personTracker.tracks(in: frames, renderedPixelSize: renderedPixelSize) {
            let found = proposeClips(
                in: track.frames, personID: track.id, renderedPixelSize: renderedPixelSize, duration: duration,
                trickModel: trickModel)
            guard !found.clips.isEmpty else { continue }
            people.append(track)
            clips += found.clips
            embeddings += found.embeddings.map { [$0] } ?? []
        }
        clips.sort { ($0.window.startTime, $0.personID ?? -1) < ($1.window.startTime, $1.personID ?? -1) }
        return DetectedClips(clips: clips, poseFrames: primary, people: people, windowEmbeddings: embeddings)
    }

    /// Steps 4-6 over a take streamed from its store, one pass per step instead of one
    /// array held through all of them: the frames are re-read from disk each pass, so a
    /// long take's memory is the result the editor needs — every scored frame, in order —
    /// plus a few seconds of working set, not the take held twice over. The steps are the
    /// same ones `detect` runs, and the result is the same one: the equivalence tests pin
    /// it. `frames` must be re-iterable — the store's sequences are — because the
    /// heuristic's crop sweep passes over the take again after the signal.
    private func detectStreaming(
        frames: () -> AnySequence<MultiPoseFrame>, people mode: PersonMode,
        renderedPixelSize: CGSize, duration: TimeInterval, trickModel: TrickModel?
    ) -> DetectedClips {
        // Pass 1: the result's frames and the motion signal, in one walk. The signal
        // streamer holds a few seconds of frames; the primaries accumulate into the
        // result — the editor needs every scored frame, so this is the run's floor.
        var poseFrames: [PoseFrameResult] = []
        var signal = StreamingMotionSignal(renderedPixelSize: renderedPixelSize)
        for frame in frames() {
            let primary = frame.primary
            poseFrames.append(primary)
            signal.consume(primary)
        }
        let samples = signal.finish()

        guard mode == .everyone else {
            if let trickModel {
                // Whole-take inference by nature: it runs over the result array, no extra
                // copy — the same call `detect` makes.
                let found = proposeClips(
                    in: poseFrames, personID: nil, renderedPixelSize: renderedPixelSize,
                    duration: duration, trickModel: trickModel)
                return DetectedClips(
                    clips: found.clips, poseFrames: poseFrames,
                    windowEmbeddings: found.embeddings.map { [$0] } ?? [])
            }
            // The heuristic's windows, from the streamed signal, then one sweep over the
            // take collecting each frame into the windows containing it — the same
            // window-to-frames pairing `buildClips` does, window by window. Windows are
            // clamped before the sweep, so a frame past the asset's end cannot land in
            // one: the batch form filters by the clamped window.
            let windows = windowDetector.detectWindows(in: samples)
                .compactMap { $0.clamped(to: duration) }
                .sorted { $0.startTime < $1.startTime }
            var inWindows: [[PoseFrameResult]] = Array(repeating: [], count: windows.count)
            for frame in frames() {
                let primary = frame.primary
                for (index, window) in windows.enumerated()
                where primary.timestamp >= window.startTime && primary.timestamp <= window.endTime {
                    inWindows[index].append(primary)
                }
            }
            var clips: [ProcessedClip] = []
            for (index, window) in windows.enumerated() {
                clips += buildClips(
                    proposed: [(window, nil)], personID: nil, frames: inWindows[index],
                    renderedPixelSize: renderedPixelSize, duration: duration)
            }
            return DetectedClips(clips: clips, poseFrames: poseFrames, windowEmbeddings: [])
        }
        var clips: [ProcessedClip] = []
        var people: [PoseTrack] = []
        var embeddings: [WindowEmbeddings] = []
        for track in personTracker.tracks(in: frames(), renderedPixelSize: renderedPixelSize) {
            let found = proposeClips(
                in: track.frames, personID: track.id, renderedPixelSize: renderedPixelSize, duration: duration,
                trickModel: trickModel)
            guard !found.clips.isEmpty else { continue }
            people.append(track)
            clips += found.clips
            embeddings += found.embeddings.map { [$0] } ?? []
        }
        clips.sort { ($0.window.startTime, $0.personID ?? -1) < ($1.window.startTime, $1.personID ?? -1) }
        return DetectedClips(clips: clips, poseFrames: poseFrames, people: people, windowEmbeddings: embeddings)
    }

    /// Steps 4-6 over one person's frames, proposed by the trick model when one is loaded. A model
    /// that fails at inference is logged and the heuristic proposes instead, so an analysis always
    /// ends with proposals from one of the two.
    private func proposeClips(
        in frames: [PoseFrameResult], personID: Int?, renderedPixelSize: CGSize, duration: TimeInterval?,
        trickModel: TrickModel?
    ) -> (clips: [ProcessedClip], embeddings: WindowEmbeddings?) {
        if let trickModel {
            do {
                var generator = SystemRandomNumberGenerator()
                let found = try trickModel.proposals(
                    over: frames, duration: duration, personID: personID, rules: proposalRules, using: &generator)
                let clips = buildClips(
                    proposed: found.clips.map { ($0.window, $0.proposal) }, personID: personID, frames: frames,
                    renderedPixelSize: renderedPixelSize, duration: duration)
                return (clips, found.embeddings)
            } catch {
                let reason = String(describing: error)
                Self.logger.error("Trick model failed, the heuristic proposes: \(reason, privacy: .public)")
            }
        }
        let windows = windowDetector.detectWindows(
            in: MotionSignalBuilder.buildSignal(from: frames, renderedPixelSize: renderedPixelSize))
        let clips = buildClips(
            proposed: windows.map { ($0, nil) }, personID: personID, frames: frames,
            renderedPixelSize: renderedPixelSize, duration: duration)
        return (clips, nil)
    }

    /// Steps 4-6 over frames that have already been scored, by the heuristic: motion signal,
    /// trick windows, crop rects. Both frame sources reach it — the file sampler above and the
    /// camera's live inference, whose results arrive in the same frame-normalized,
    /// display-orientation space with file-relative timestamps at the same sample rate.
    func detectClips(
        in frames: [PoseFrameResult], renderedPixelSize: CGSize, duration: TimeInterval? = nil
    ) -> [ProcessedClip] {
        proposeClips(
            in: frames, personID: nil, renderedPixelSize: renderedPixelSize, duration: duration, trickModel: nil
        ).clips
    }

    /// Pairs each detected window with the sampled frames inside it and computes its crop rect.
    func buildClips(
        windows: [TrickWindow],
        frames: [PoseFrameResult],
        renderedPixelSize: CGSize,
        duration: TimeInterval? = nil
    ) -> [ProcessedClip] {
        buildClips(
            proposed: windows.map { ($0, nil) }, personID: nil, frames: frames,
            renderedPixelSize: renderedPixelSize, duration: duration)
    }

    /// Pairs each proposed window with the sampled frames inside it and computes its crop
    /// rect. A window whose frames carry no usable keypoints still becomes a clip, with a
    /// full-frame rect: the trick was detected, so dropping it would hide a real candidate from
    /// triage; the editor can tighten the crop.
    /// With a duration, windows are clamped to the asset first, and a window
    /// with nothing inside the asset is dropped: it cannot become a clip,
    /// and a zero-length window would break the looper and the export.
    private func buildClips(
        proposed: [(window: TrickWindow, proposal: ModelProposal?)],
        personID: Int?,
        frames: [PoseFrameResult],
        renderedPixelSize: CGSize,
        duration: TimeInterval?
    ) -> [ProcessedClip] {
        proposed.compactMap { candidate in
            var window = candidate.window
            if let duration {
                guard let clamped = window.clamped(to: duration) else { return nil }
                window = clamped
            }
            let inWindow = frames.filter {
                $0.timestamp >= window.startTime && $0.timestamp <= window.endTime
            }
            let cropRect = cropRectCalculator.cropRect(
                for: inWindow, renderedPixelSize: renderedPixelSize)
                ?? NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
            return ProcessedClip(window: window, cropRect: cropRect, personID: personID, proposal: candidate.proposal)
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

/// The first sampled frame's render size: the composition grid the run's frames were
/// rendered onto, in display orientation. The sampler builds one composition per run, so
/// the first frame's size stands for all of them; pose keypoints are measured in this
/// space, so the crop math denormalizes against it rather than the track's encoded
/// `naturalSize`. The sampler's handler is `@Sendable` and runs off the main actor, so
/// the size crosses through this actor rather than a captured `var`. Nil when the
/// sampler produced no frame.
private actor FirstRenderSize {
    private(set) var value: CGSize?

    /// Records the first size seen; later frames keep the same composition.
    func set(_ size: CGSize) {
        if value == nil {
            value = size
        }
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
