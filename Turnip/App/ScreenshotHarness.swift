#if DEBUG
import AVFoundation
import CoreVideo
import os
import Photos
import SwiftUI

// MARK: - Home

/// Home's Photos-denied empty state (`-screenshotHome`).
///
/// A populated grid is what's actually unscriptable without the Photos library -- it
/// needs real `PHAsset`s, which have no public initializer. This state and
/// `ScreenshotGalleryFilterHarness` below both sidestep that by never rendering a grid;
/// launching the real `HomeView` and letting it fetch would raise the system permission
/// prompt in the simulator. The denied state here is pure
/// SwiftUI and deterministic.
struct ScreenshotHomeHarness: View {
    // Isolated suite, like `ScreenshotSettingsHarness` — a tap here must never read or
    // write the app's real stored preferences.
    private static let store = TurnipSettingsStore(
        defaults: UserDefaults(suiteName: "ScreenshotHomeHarness") ?? .standard)
    @State private var showSettings = false
    // Real `VideoLibraryViewModel` — not a hand-built stand-in — so `GalleryFilterButton`'s
    // `.disabled` wiring below is the same code path production uses. Forced to `.denied`
    // rather than reading the CI simulator's actual (un-prompted) PHPhotoLibrary status: this
    // view never calls `start()`, so nothing here ever raises the real permission prompt, but
    // the *value* of an un-prompted status is a property of the simulator image, not of this
    // harness, and this harness needs to be deterministic.
    @StateObject private var viewModel = VideoLibraryViewModel(authorization: .denied(restricted: false))

    var body: some View {
        NavigationStack {
            // Same composition as `HomeView`'s denied branch: the wordmark header as content
            // under Home's empty, transparent bar, with `HomeNavigationBar` placing the same
            // filter/settings controls `HomeView.body` gets. Wired to a real sheet present,
            // not a no-op action, so a UI test can `.tap()` a button and assert the sheet
            // actually opened — the behavior the button exists for, not just its presence in
            // the hit-testing tree.
            VStack(spacing: 0) {
                HomeHeader()
                PhotosAccessDeniedView(restricted: false)
            }
            .modifier(HomeNavigationBar(viewModel: viewModel, showSettings: { showSettings = true }))
            .sheet(isPresented: $showSettings) { SettingsView(settings: Self.store) }
        }
    }
}

/// Gallery filter menu, open (`-screenshotGalleryFilter`): the actual feature the button in
/// `ScreenshotHomeHarness` above only proves is disabled without access. Forced to `.authorized`
/// so the button is enabled -- and, same as that harness, `reload()`/`start()` are never called,
/// so this never touches the real `PHPhotoLibrary` or depends on the CI simulator's library
/// contents. The menu's rows only read `viewModel.filter` and `viewModel.albums` (empty here,
/// which just hides the Album submenu), not `videos`/`hasLoaded`, so the backdrop behind the
/// open menu is the same not-yet-loaded spinner state `HomeView` shows before its first fetch
/// completes -- deterministic, and not claiming a populated grid this harness never fetched.
struct ScreenshotGalleryFilterHarness: View {
    @StateObject private var viewModel = VideoLibraryViewModel(authorization: .authorized)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HomeHeader()
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .modifier(HomeNavigationBar(viewModel: viewModel, showSettings: {}))
        }
    }
}

// MARK: - Name Clips

/// Name Clips (`-screenshotClipList`): three detected windows. Cards render as their placeholder
/// — `/dev/null` decodes nothing, and the loader fails gracefully to the placeholder (the honest
/// fallback).
struct ScreenshotClipListHarness: View {
    var body: some View {
        NavigationStack {
            NameClipsView(
                items: [
                    ClipListItem(
                        window: TrickWindow(startTime: 2, endTime: 5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                    ClipListItem(
                        window: TrickWindow(startTime: 9, endTime: 11.5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                    ClipListItem(
                        window: TrickWindow(startTime: 20, endTime: 22.4),
                        cropRect: NormalizedRect(minX: 0.1, maxX: 0.9, minY: 0.2, maxY: 0.8))
                ],
                asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                assetIdentifier: "screenshot",
                duration: 24)
        }
    }
}

/// Name Clips over real media (`-screenshotClipListMedia`): two clips within the generated
/// sample movie's six seconds, so — unlike `-screenshotClipList`'s `/dev/null` asset — the asset
/// duration actually loads and each card's range timeline renders. Shares
/// `ScreenshotClipEditorHarness`'s sample-movie writer and warm-up.
///
/// The first clip is seeded as already saved, the state a save that partially failed leaves:
/// it is the only way the saved badge reaches a rendered screen, since nothing a UI test can
/// drive from a cold launch performs a real Photos write. Real media because the editor needs
/// it to open, and opening it from the badge's own corner proves the badge does not shadow the
/// card's tap.
struct ScreenshotClipListMediaHarness: View {
    var body: some View {
        HarnessMovieGate(ScreenshotClipEditorHarness.sampleMovie) { movie in
            NavigationStack {
                clipList(asset: AVURLAsset(url: movie.url))
            }
        }
    }

    private func clipList(asset: AVURLAsset) -> some View {
        NameClipsView(
                items: [
                    ClipListItem(
                        window: TrickWindow(startTime: 0.5, endTime: 2),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
                        isSaved: true),
                    ClipListItem(
                        window: TrickWindow(startTime: 3, endTime: 4.5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
                ],
                asset: asset,
                assetIdentifier: "screenshot",
                duration: 6)
    }
}

// MARK: - Clip editor

/// Clip editor (`-screenshotClipEditor`): the trimmed clip looping with its live crop
/// rect and the trim slider, in Still for the Still-mode tests, or in Follow with `-follow`,
/// the mode every clip opens in.
///
/// The editor needs real media — `/dev/null` isn't one, so `prepare()` takes the
/// load-failure path and the screenshot would show "Couldn't load this clip", which
/// reads as a broken screen. The harness writes a tiny generated sample movie (six
/// seconds of solid-color frames) so it renders the real editor UI instead. Same
/// `AVAssetWriter` pattern as the `ClipEditorView` preview. If generation fails the
/// URL falls back to `/dev/null` and the harness degrades to the (deterministic)
/// load-failure state instead of crashing, with the reason drawn over it
/// (`sampleMovieFailureNote(_:)`).
struct ScreenshotClipEditorHarness: View {
    /// Generated once per process: `prepare()` needs the file to exist before the
    /// view appears, and re-encoding on every body evaluation would be wasteful.
    /// `static let` is lazily initialized and thread-safe, but it initializes on
    /// the accessing thread — so `warmUpSampleMovie()` starts it on a background
    /// queue from `TurnipApp.init()` (when a harness that uses the sample movie is
    /// launched) before any view appears, keeping the encode off the UI thread.
    fileprivate static let sampleMovie = makeScreenshotSampleMovie()
    /// The roll written into the sample movie's track: a small, clearly non-zero tilt,
    /// so Auto rotate has something to level and the result is visibly a turn.
    static let sampleRollTilt = 3.0 * .pi / 180

    /// A standing pose at every half second of the sample movie, so Auto crop has
    /// keypoints to frame in whatever window the trim handles hold — the same stick
    /// figure the Processing pose harness draws, which the crop fit only needs to be
    /// located, not accurate.
    private static let samplePoseFrames: [PoseFrameResult] = (0...12).map { index in
        PoseFrameResult(
            frameIndex: index * 15, timestamp: Double(index) / 2,
            keypoints: ScreenshotProcessingPoseRunner.sampleKeypoints)
    }

    /// Starts the sample-movie encode on a background queue ahead of first use.
    /// Called from `TurnipApp.init()` when a harness that uses the sample movie is
    /// launched, so the encode is under way, or done, by the time `HarnessMovieGate`
    /// first asks for the movie, and the harness shows sooner.
    static func warmUpSampleMovie() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.sampleMovie
        }
    }

    var body: some View {
        HarnessMovieGate(Self.sampleMovie) { movie in
            NavigationStack {
                ClipEditorView(
                    source: ClipEditorSource(
                        window: TrickWindow(startTime: 2, endTime: 5),
                        cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.25, maxY: 0.75),
                        framingMode: CommandLine.arguments.contains("-follow") ? .follow : .still,
                        asset: AVURLAsset(url: movie.url),
                        poseFrames: Self.samplePoseFrames),
                    onCommit: { _ in })
            }
        }
    }
}

/// The harnesses' sample movie, or why there isn't one.
struct ScreenshotSampleMovie: Sendable {
    /// The movie's file, or `/dev/null` when the encode failed.
    let url: URL
    /// What failed, step by step, with how long each attempt ran. Drawn over the harness so a
    /// UI test that lands on the load-failure state can put it in its failure message: the
    /// log it also goes to isn't captured on CI.
    let failure: String?
}

extension View {
    /// A harness movie's encode failure, if there was one, as text the UI tests find by
    /// `HarnessIdentifier.sampleMovieFailure`.
    func sampleMovieFailureNote(_ movie: ScreenshotSampleMovie) -> some View {
        overlay(alignment: .bottom) {
            if let failure = movie.failure {
                Text(failure)
                    .font(.caption2)
                    .padding(4)
                    .background(.background)
                    .accessibilityIdentifier(HarnessIdentifier.sampleMovieFailure)
            }
        }
    }
}

/// Shows a harness once its movie is ready, reading it off the main thread. The movies are
/// lazy statics, and a `body` that read one while the encode was still running would block
/// the main thread until it finished: the app froze, and the UI tests' queries with it, for
/// as long as the encoder took.
struct HarnessMovieGate<Content: View>: View {
    private let movie: @Sendable () -> ScreenshotSampleMovie
    private let content: (ScreenshotSampleMovie) -> Content
    @State private var loaded: ScreenshotSampleMovie?

    init(
        _ movie: @autoclosure @escaping @Sendable () -> ScreenshotSampleMovie,
        @ViewBuilder content: @escaping (ScreenshotSampleMovie) -> Content
    ) {
        self.movie = movie
        self.content = content
    }

    var body: some View {
        ZStack {
            if let loaded {
                content(loaded).sampleMovieFailureNote(loaded)
            } else {
                ProgressView()
            }
        }
        .task {
            let movie = movie
            loaded = await Task.detached(priority: .userInitiated) { movie() }.value
        }
    }
}

/// Where a harness movie is kept between launches of one build of the app. The UI tests
/// launch the app dozens of times a run, and encoding on every launch gave a slow or failing
/// encoder on a loaded CI runner that many chances to cost a test. The file name carries the
/// build's executable date, so a rebuilt app, whose harness may draw differently, encodes
/// afresh. The movie is written under a temporary name and moved into place once complete,
/// so a launch killed mid-encode leaves nothing a later launch would take for a movie.
enum HarnessMovieFile {
    /// This build's movie called `name`, encoded with `encode` unless an earlier launch of the
    /// same build already did, which `reused` says.
    static func movie(named name: String, encode: (URL) throws -> Void) throws -> (url: URL, reused: Bool) {
        let fileManager = FileManager.default
        let directory = URL.temporaryDirectory
        let url = directory.appending(path: "\(name)-\(buildStamp).mov")
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            return (url, true)
        }
        let earlier = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in earlier where file.lastPathComponent.hasPrefix("\(name)-") {
            try? fileManager.removeItem(at: file)
        }
        let partial = directory.appending(path: "\(name)-partial.mov")
        try encode(partial)
        try fileManager.moveItem(at: partial, to: url)
        return (url, false)
    }

    private static let buildStamp: Int = {
        let values = try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey])
        return Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }()
}

/// Writes the sample movie for `ScreenshotClipEditorHarness`: six seconds of
/// solid-color H.264 frames at 320x568, once per build (`HarnessMovieFile`).
/// Synchronous; `warmUpSampleMovie()` starts it on a background queue before any view
/// appears, and `HarnessMovieGate` waits for it off the main thread. Falls back to
/// `/dev/null` (the deterministic load-failure state) if anything fails, instead of crashing.
///
/// A failure of the writer itself gets one more attempt. A frame that ran out its deadline
/// doesn't: that is an encoder crawling under load, and a second crawl would carry the harness
/// past the UI test's own wait, trading the reason for a bare timeout.
private func makeScreenshotSampleMovie() -> ScreenshotSampleMovie {
    var attempts: [String] = []
    let logger = Logger(subsystem: "com.hoiekim.turnip", category: "ScreenshotHarness")
    for _ in 1...2 {
        let started = Date()
        do {
            let file = try HarnessMovieFile.movie(named: "ScreenshotSample") { try encodeScreenshotSampleMovie(to: $0) }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            let how = file.reused ? "reused" : "encoded"
            logger.notice("sample movie \(how, privacy: .public) in \(seconds, privacy: .public) s")
            return ScreenshotSampleMovie(url: file.url, failure: nil)
        } catch {
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            attempts.append("\(error) after \(seconds) s")
            guard (error as? ScreenshotMovieError)?.isWriterFailure == true else { break }
        }
    }
    let failure = "sample movie encode failed: " + attempts.joined(separator: "; then ")
    logger.error("\(failure, privacy: .public)")
    return ScreenshotSampleMovie(url: URL(fileURLWithPath: "/dev/null"), failure: failure)
}

/// One attempt at the sample movie, start to finish.
private func encodeScreenshotSampleMovie(to url: URL) throws {
    // A stale file from a killed run, or a failed attempt, would make the writer's creation fail.
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let width = 320
    let height = 568
    let fps: Int32 = 30
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
    // Inputs go in before writing starts: `add(_:)` raises an uncaught NSException
    // once the writer is in `.writing`, which no `catch` here can turn into the
    // `/dev/null` fallback.
    guard writer.canAdd(input) else { throw ScreenshotMovieError.setupFailed("can't add the video input") }
    writer.add(input)
    let rollInput = AVAssetWriterInput(
        mediaType: .metadata, outputSettings: nil, sourceFormatHint: try RollTrack.makeFormatDescription())
    rollInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(rollInput) else { throw ScreenshotMovieError.setupFailed("can't add the roll input") }
    writer.add(rollInput)
    // Like the pixel buffer adaptor above, created before writing starts: an adaptor
    // made for an input that is already writing raises an uncaught NSException.
    let rollAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: rollInput)
    guard writer.startWriting() else { throw ScreenshotMovieError.writerFailed(step: "start", error: writer.error) }
    try appendSampleFrames(
        writer: writer, adaptor: adaptor, input: input, roll: (rollAdaptor, rollInput), fps: fps)
    input.markAsFinished()
    rollInput.markAsFinished()
    try finishSampleMovieWriting(writer: writer)
}

/// Starts the writer session and encodes the solid-color frames, each followed by that
/// frame's roll sample. The two inputs advance together, frame by frame: a writer
/// interleaves its inputs, and one left seconds ahead of the other stops reporting ready
/// for data until the other catches up, which would stall the encode. The caller
/// marks both inputs finished. Extracted from `encodeScreenshotSampleMovie(to:)` so each
/// function stays under the repo's SwiftLint `function_body_length` limit.
private func appendSampleFrames(
    writer: AVAssetWriter,
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    input: AVAssetWriterInput,
    roll: (adaptor: AVAssetWriterInputMetadataAdaptor, input: AVAssetWriterInput),
    fps: Int32
) throws {
    writer.startSession(atSourceTime: .zero)
    for frame in 0 ..< (6 * Int(fps)) {
        try appendSolidFrame(adaptor: adaptor, input: input, writer: writer, frame: frame, fps: fps)
        try appendRollSample(adaptor: roll.adaptor, input: roll.input, writer: writer, frame: frame, fps: fps)
    }
}

/// One sample of the sample movie's roll track (`RollTrack`), at
/// `ScreenshotClipEditorHarness.sampleRollTilt`, the way an in-app take carries its own:
/// the editor's Auto rotate then levels the harness clip by the real reader, so the UI
/// test that taps it sees "Reset rotate" without a horizon in the picture.
private func appendRollSample(
    adaptor: AVAssetWriterInputMetadataAdaptor,
    input: AVAssetWriterInput,
    writer: AVAssetWriter,
    frame: Int,
    fps: Int32
) throws {
    let deadline = Date().addingTimeInterval(15)
    while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.002)
    }
    guard input.isReadyForMoreMediaData else {
        throw ScreenshotMovieError.notReady(writer: writer, input: "roll", frame: frame)
    }
    let group = RollTrack.timedGroup(
        tilt: ScreenshotClipEditorHarness.sampleRollTilt,
        start: CMTime(value: CMTimeValue(frame), timescale: fps))
    guard adaptor.append(group) else {
        throw ScreenshotMovieError.writerFailed(step: "append roll sample \(frame)", error: writer.error)
    }
}

/// Waits for a harness movie's writer to finish, throwing on failure, or when it hasn't
/// finished in 30 s: a writer that never calls back would otherwise leave the harness
/// waiting for its movie past every UI test's wait, with no reason given.
func finishSampleMovieWriting(writer: AVAssetWriter) throws {
    let finished = DispatchSemaphore(value: 0)
    // The completion handler runs off the main thread, so waiting here can't deadlock.
    writer.finishWriting { finished.signal() }
    guard finished.wait(timeout: .now() + 30) == .success else {
        throw ScreenshotMovieError.finishTimedOut
    }
    guard writer.status == .completed else {
        throw ScreenshotMovieError.writerFailed(step: "finish", error: writer.error)
    }
}

/// Encodes one solid-color frame into the sample movie. The fill varies per frame so
/// the encoder emits real (non-skipped) frames.
private func appendSolidFrame(
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    input: AVAssetWriterInput,
    writer: AVAssetWriter,
    frame: Int,
    fps: Int32
) throws {
    // Bounded on writer status: if the writer fails mid-write,
    // `isReadyForMoreMediaData` never becomes true, and without the status
    // check the loop would spin with no cause. Bounded by wall clock, not a
    // spin count: on a loaded shared CI runner the encoder can stay busy far
    // longer than on a developer machine, and a budget that runs out fails the
    // encode, degrading the harness to the `/dev/null` load-failure fallback.
    // The budget is per frame and deliberately generous; a healthy encoder is
    // ready in single-digit milliseconds.
    let deadline = Date().addingTimeInterval(15)
    while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.002)
    }
    guard input.isReadyForMoreMediaData else {
        throw ScreenshotMovieError.notReady(writer: writer, input: "video", frame: frame)
    }
    guard let pool = adaptor.pixelBufferPool else {
        throw ScreenshotMovieError.writerFailed(step: "pixel buffer pool at frame \(frame)", error: writer.error)
    }
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
        throw ScreenshotMovieError.setupFailed("pixel buffer at frame \(frame): CVReturn \(status)")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        // Vary the fill per frame so the encoder emits real (non-skipped) frames.
        memset(base, Int32(frame % 255), bytes)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let time = CMTime(value: CMTimeValue(frame), timescale: fps)
    guard adaptor.append(buffer, withPresentationTime: time) else {
        throw ScreenshotMovieError.writerFailed(step: "append video frame \(frame)", error: writer.error)
    }
}

/// Why a harness movie couldn't be written, worded for the UI test's failure message.
enum ScreenshotMovieError: Error, CustomStringConvertible {
    case setupFailed(String)
    /// An input stayed busy past its per-frame deadline while the writer was still writing.
    case timedOut(input: String, frame: Int)
    /// Every frame went in, but the writer didn't finish the file in time.
    case finishTimedOut
    /// The writer itself failed, with AVFoundation's error when it gave one.
    case writerFailed(step: String, error: Error?)

    /// An input that never became ready: a deadline that ran out if the writer is still
    /// writing, the writer's own failure otherwise.
    static func notReady(writer: AVAssetWriter, input: String, frame: Int) -> ScreenshotMovieError {
        writer.status == .writing
            ? .timedOut(input: input, frame: frame)
            : .writerFailed(step: "\(input) input at frame \(frame)", error: writer.error)
    }

    var isWriterFailure: Bool {
        if case .writerFailed = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .setupFailed(let what):
            return "setup failed: \(what)"
        case let .timedOut(input, frame):
            return "\(input) input not ready within 15 s at frame \(frame)"
        case .finishTimedOut:
            return "writer didn't finish within 30 s"
        case let .writerFailed(step, error):
            return "writer failed at \(step): \(error.map { String(describing: $0) } ?? "no error given")"
        }
    }
}

// MARK: - Processing

/// Processing mid-run (`-screenshotProcessing`): the stub runner reports one progress
/// report ("Analyzing frame 400 of 1200") and then holds the run open so the UI test
/// screenshots the progress state — the test runner kills the app before the hold
/// expires. No inference, no model, no video file.
struct ScreenshotProcessingHarness: View {
    var body: some View {
        NavigationStack {
            ProcessingView(
                video: SelectedVideo(
                    assetIdentifier: "screenshot",
                    asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                    duration: 60),
                runner: ScreenshotProcessingRunner(),
                destination: { _, _ in EmptyView() })
        }
    }
}

/// Processing mid-run with the pose overlay (`-screenshotProcessingPose`): real media
/// (shares `ScreenshotClipEditorHarness`'s sample movie) so the scrub-to-progress and
/// skeleton-overlay feature has an actual displayed frame to land on, unlike
/// `-screenshotProcessing`'s `/dev/null` asset.
struct ScreenshotProcessingPoseHarness: View {
    var body: some View {
        HarnessMovieGate(ScreenshotClipEditorHarness.sampleMovie) { movie in
            NavigationStack {
                ProcessingView(
                    video: SelectedVideo(
                        assetIdentifier: "screenshot",
                        asset: AVURLAsset(url: movie.url),
                        duration: 6),
                    runner: ScreenshotProcessingPoseRunner(),
                    destination: { _, _ in EmptyView() })
            }
        }
    }
}

/// Scripted `ProcessingRunning` for `-screenshotProcessingPose`: one mid-run report
/// with a stick-figure's worth of keypoints at a fixed timestamp, then holds — same
/// hold-and-let-the-UI-test-kill-it shape as `ScreenshotProcessingRunner`.
struct ScreenshotProcessingPoseRunner: ProcessingRunning {
    func run(
        video: SelectedVideo,
        people: PersonMode,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        await onProgress(ProcessingProgress(
            frame: 40, totalFrames: 90, timestamp: 3, skeletons: [Self.sampleKeypoints]))
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    /// A rough standing pose in frame-normalized (display-orientation) coordinates —
    /// enough to show the overlay is landing on the video, not to prove pose accuracy.
    static let sampleKeypoints: [PoseKeypoint] = [
        ("nose", 0.5, 0.15), ("left_eye", 0.47, 0.14), ("right_eye", 0.53, 0.14),
        ("left_ear", 0.44, 0.15), ("right_ear", 0.56, 0.15),
        ("left_shoulder", 0.4, 0.25), ("right_shoulder", 0.6, 0.25),
        ("left_elbow", 0.35, 0.4), ("right_elbow", 0.65, 0.4),
        ("left_wrist", 0.32, 0.53), ("right_wrist", 0.68, 0.53),
        ("left_hip", 0.43, 0.55), ("right_hip", 0.57, 0.55),
        ("left_knee", 0.42, 0.72), ("right_knee", 0.58, 0.72),
        ("left_ankle", 0.41, 0.9), ("right_ankle", 0.59, 0.9)
    ].map { name, x, y in PoseKeypoint(name: name, y: Float(y), x: Float(x), confidence: 0.9) }
}

/// Processing's resting state (`-screenshotProcessingIdle`): the picked video filling
/// the screen with no native playback chrome, the thin scrub bar, and the manual
/// "Analyze clips" button. `autostart: false` so the pipeline never actually runs.
/// The destination is a labeled stand-in rather than `EmptyView`, so the UI test that taps
/// "Clip manually" can see the push land and read the result it landed with.
struct ScreenshotProcessingIdleHarness: View {
    var body: some View {
        NavigationStack {
            ProcessingView(
                video: SelectedVideo(
                    assetIdentifier: "screenshot",
                    asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                    duration: 60),
                autostart: false,
                destination: { result, _ in
                    Text(result.analysisSkipped ? "Clip list stand-in: skipped" : "Clip list stand-in")
                        .accessibilityIdentifier("clip-list-stand-in")
                })
        }
    }
}

/// Scripted `ProcessingRunning` for the harness: one mid-run progress report, then hold.
private struct ScreenshotProcessingRunner: ProcessingRunning {
    func run(
        video: SelectedVideo,
        people: PersonMode,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        await onProgress(ProcessingProgress(frame: 400, totalFrames: 1200))
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

// MARK: - Processing swipe-to-browse

/// Processing inside the same page container the app runs it in (`-screenshotProcessingBrowse`):
/// a stand-in Camera page, then a `NavigationStack` with a Processing screen pushed over a
/// stand-in Home, wired to three stand-in videos with solid-color posters and the same
/// `PageSwipeLock` `RootTabView` applies. The UI test swipes and reads the screen's center
/// color to tell which video landed — and whether the swipe reached the pager instead. The
/// `/dev/null` assets never decode a frame, so the poster under each player is what shows.
struct ScreenshotProcessingBrowseHarness: View {
    static let colors: [UIColor] = [.systemRed, .systemGreen, .systemBlue]
    @State private var selectedTab = MainTab.home
    @State private var path: [Int] = [1]

    var body: some View {
        TabView(selection: $selectedTab) {
            Color.gray
                .ignoresSafeArea()
                .accessibilityIdentifier("camera-stand-in")
                .tag(MainTab.camera)
            NavigationStack(path: $path) {
                Text("Home stand-in")
                    .navigationDestination(for: Int.self) { index in
                        ProcessingView(
                            video: Self.video(index),
                            autostart: false,
                            poster: Self.poster(index),
                            previous: neighbor(index - 1),
                            next: neighbor(index + 1),
                            destination: { _, _ in EmptyView() })
                        .id(index)
                    }
            }
            .background(PageSwipeLock(swipeEnabled: path.isEmpty))
            .tag(MainTab.home)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    private func neighbor(_ index: Int) -> BrowseNeighbor? {
        guard Self.colors.indices.contains(index) else { return nil }
        return BrowseNeighbor(poster: Self.poster(index)) {
            path[path.count - 1] = index
            return true
        }
    }

    private static func video(_ index: Int) -> SelectedVideo {
        SelectedVideo(
            assetIdentifier: "stand-in-\(index)",
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            duration: 60)
    }

    /// A portrait solid-color poster; the size only matters for its aspect ratio.
    private static func poster(_ index: Int) -> PosterLoader {
        { _ in
            let size = CGSize(width: 90, height: 160)
            return UIGraphicsImageRenderer(size: size).image { context in
                colors[index].setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
    }
}

// MARK: - Home expansion fallback destination

/// `HomeExpansionContainer` in isolation (`-screenshotHomeExpansion`), verifying its
/// fallback-destination math without needing a real `PHAsset` or a `ProcessingView`
/// measurement to ever arrive — `content` here never reports
/// `ProcessingVideoFramePreferenceKey`, so `measuredDestination` stays `nil` for the
/// whole run and `fallbackDestination(in:)` is the only thing under test: given a
/// deliberately wide `initialAspectRatio` (16:9 in a portrait window), the flying card
/// should settle into a letterboxed band, never the full screen. A UI test reads the
/// card's own laid-out frame (`"expansion-card"` — accessibility reports geometry
/// regardless of the card's current opacity) once the opening flight has landed.
struct ScreenshotHomeExpansionHarness: View {
    var body: some View {
        HomeExpansionContainer(
            sourceFrame: { CGRect(x: 20, y: 100, width: 100, height: 100) },
            thumbnail: Self.solidImage(.systemRed),
            initialAspectRatio: CGSize(width: 16, height: 9),
            content: { _ in Color.clear }
        )
    }

    /// 16:9, matching `initialAspectRatio` above — a mismatched thumbnail aspect ratio would
    /// make `cardLayer`'s `.scaledToFill()` overflow its clipped box, which is a confound a UI
    /// test reading this accessibility frame doesn't want: an `Image` leaf's accessibility frame
    /// reflects its own post-fill, pre-clip render size, not the outer `.frame().clipped()` box,
    /// so a mismatched source would make even a correct `fallbackDestination` look wrong here.
    private static func solidImage(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 16, height: 9)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Settings

/// Settings sheet (`-screenshotSettings`): the four preferences at their defaults, backed by
/// an isolated `UserDefaults` suite so a screenshot run never reads or writes the app's real
/// stored preferences.
struct ScreenshotSettingsHarness: View {
    private static let store = TurnipSettingsStore(
        defaults: UserDefaults(suiteName: "ScreenshotSettingsHarness") ?? .standard)

    var body: some View {
        SettingsView(settings: Self.store)
    }
}
#endif
