#if DEBUG
import AVFoundation
import CoreVideo
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

// MARK: - Clip list

/// Clip list triage (`-screenshotClipList`): three detected windows, one trashed.
/// Thumbnails render as their placeholder tiles — `/dev/null` decodes nothing, and
/// the loader fails gracefully to the placeholder (the honest fallback).
struct ScreenshotClipListHarness: View {
    var body: some View {
        NavigationStack {
            ClipListView(
                items: [
                    ClipListItem(
                        window: TrickWindow(startTime: 2, endTime: 5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                    ClipListItem(
                        window: TrickWindow(startTime: 9, endTime: 11.5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                    ClipListItem(
                        window: TrickWindow(startTime: 20, endTime: 22.4),
                        cropRect: NormalizedRect(minX: 0.1, maxX: 0.9, minY: 0.2, maxY: 0.8),
                        isTrashed: true)
                ],
                asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                assetIdentifier: "screenshot",
                duration: 24)
        }
    }
}

/// Clip list over real media (`-screenshotClipListMedia`): two clips within the
/// generated sample movie's six seconds, so — unlike `-screenshotClipList`'s `/dev/null`
/// asset — the asset duration actually loads and each tile's inline trim timeline
/// renders instead of staying hidden behind its `if let duration` guard. Shares
/// `ScreenshotClipEditorHarness`'s sample-movie writer and warm-up.
struct ScreenshotClipListMediaHarness: View {
    var body: some View {
        NavigationStack {
            ClipListView(
                items: [
                    ClipListItem(
                        window: TrickWindow(startTime: 0.5, endTime: 2),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                    ClipListItem(
                        window: TrickWindow(startTime: 3, endTime: 4.5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
                ],
                asset: AVURLAsset(url: ScreenshotClipEditorHarness.sampleMovieURL),
                assetIdentifier: "screenshot",
                duration: 6)
        }
    }
}

// MARK: - Clip editor

/// Clip editor (`-screenshotClipEditor`): the trimmed clip looping with its live crop
/// rect and the trim slider.
///
/// The editor needs real media — `/dev/null` isn't one, so `prepare()` takes the
/// load-failure path and the screenshot would show "Couldn't load this clip", which
/// reads as a broken screen. The harness writes a tiny generated sample movie (six
/// seconds of solid-color frames) so it renders the real editor UI instead. Same
/// `AVAssetWriter` pattern as the `ClipEditorView` preview. If generation fails the
/// URL falls back to `/dev/null` and the harness degrades to the (deterministic)
/// load-failure state instead of crashing.
struct ScreenshotClipEditorHarness: View {
    /// Generated once per process: `prepare()` needs the file to exist before the
    /// view appears, and re-encoding on every body evaluation would be wasteful.
    /// `static let` is lazily initialized and thread-safe, but it initializes on
    /// the accessing thread — so `warmUpSampleMovie()` starts it on a background
    /// queue from `TurnipApp.init()` (when the `-screenshotClipEditor` launch arg
    /// is present) before any view appears, keeping the encode off the UI thread.
    fileprivate static let sampleMovieURL: URL = makeScreenshotSampleMovie()

    /// Starts the sample-movie encode on a background queue ahead of first use.
    /// Called from `TurnipApp.init()` when the `-screenshotClipEditor` launch arg
    /// is present, so the first render usually doesn't stall on the encode. (If
    /// the encode hasn't finished when `body` first touches `sampleMovieURL`,
    /// the main thread still blocks on the lazy initializer until it completes —
    /// the warm-up makes that rare, not impossible.)
    static func warmUpSampleMovie() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.sampleMovieURL
        }
    }

    var body: some View {
        NavigationStack {
            ClipEditorView(
                source: ClipEditorSource(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.25, maxY: 0.75),
                    asset: AVURLAsset(url: Self.sampleMovieURL),
                    poseFrames: []),
                onCommit: { _ in },
                onDelete: {})
        }
    }
}

/// Writes the sample movie for `ScreenshotClipEditorHarness`: six seconds of
/// solid-color H.264 frames at 320x568. Synchronous; `warmUpSampleMovie()` starts
/// it on a background queue before any view appears, so the main thread never
/// stalls on the encode. Re-created at a fixed filename each run, so screenshot
/// runs never litter tmp/ with orphaned sample movies. Falls back to `/dev/null`
/// (the deterministic load-failure state) if anything fails, instead of crashing.
private func makeScreenshotSampleMovie() -> URL {
    // Fixed filename: each run replaces the previous file rather than adding one.
    let url = URL.temporaryDirectory.appending(path: "ScreenshotSample.mov")
    // A stale file from a killed run would make the writer's creation fail.
    try? FileManager.default.removeItem(at: url)
    do {
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
        guard writer.canAdd(input) else { throw ScreenshotMovieError.setupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ScreenshotMovieError.setupFailed }
        try appendSampleFrames(writer: writer, adaptor: adaptor, input: input, fps: fps)
        return try finishSampleMovieWriting(writer: writer, to: url)
    } catch {
        try? FileManager.default.removeItem(at: url)
        return URL(fileURLWithPath: "/dev/null")
    }
}

/// Starts the writer session and encodes the solid-color frames, then marks the
/// input finished. Extracted from `makeScreenshotSampleMovie()` so each function
/// stays under the repo's SwiftLint `function_body_length` limit.
private func appendSampleFrames(
    writer: AVAssetWriter,
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    input: AVAssetWriterInput,
    fps: Int32
) throws {
    writer.startSession(atSourceTime: .zero)
    for frame in 0 ..< (6 * Int(fps)) {
        try appendSolidFrame(adaptor: adaptor, input: input, writer: writer, frame: frame, fps: fps)
    }
    input.markAsFinished()
}

/// Waits for the writer to finish and returns the movie URL on success, throwing
/// on failure. Extracted from `makeScreenshotSampleMovie()` so each function stays
/// under the repo's SwiftLint `function_body_length` limit.
private func finishSampleMovieWriting(writer: AVAssetWriter, to url: URL) throws -> URL {
    let finished = DispatchSemaphore(value: 0)
    // The completion handler runs off the main thread, so waiting here can't deadlock.
    writer.finishWriting { finished.signal() }
    finished.wait()
    guard writer.status == .completed else { throw ScreenshotMovieError.finishFailed }
    return url
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
    // check the loop would spin with no cause. Finishes in well under a second
    // for the few hundred local frames.
    var spins = 0
    while !input.isReadyForMoreMediaData, writer.status == .writing, spins < 500 {
        Thread.sleep(forTimeInterval: 0.002)
        spins += 1
    }
    guard let pool = adaptor.pixelBufferPool else {
        throw ScreenshotMovieError.setupFailed
    }
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
        throw ScreenshotMovieError.setupFailed
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
        throw ScreenshotMovieError.appendFailed
    }
}

private enum ScreenshotMovieError: Error {
    case setupFailed, appendFailed, finishFailed
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
        NavigationStack {
            ProcessingView(
                video: SelectedVideo(
                    assetIdentifier: "screenshot",
                    asset: AVURLAsset(url: ScreenshotClipEditorHarness.sampleMovieURL),
                    duration: 6),
                runner: ScreenshotProcessingPoseRunner(),
                destination: { _, _ in EmptyView() })
        }
    }
}

/// Scripted `ProcessingRunning` for `-screenshotProcessingPose`: one mid-run report
/// with a stick-figure's worth of keypoints at a fixed timestamp, then holds — same
/// hold-and-let-the-UI-test-kill-it shape as `ScreenshotProcessingRunner`.
private struct ScreenshotProcessingPoseRunner: ProcessingRunning {
    func run(
        video: SelectedVideo,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        await onProgress(ProcessingProgress(
            frame: 40, totalFrames: 90, timestamp: 3, keypoints: Self.sampleKeypoints))
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    /// A rough standing pose in frame-normalized (display-orientation) coordinates —
    /// enough to show the overlay is landing on the video rather than proving pose
    /// accuracy, which is `PoseDiagnosticView`'s job.
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
/// "Start analysis" button. `autostart: false` so the pipeline never actually runs.
struct ScreenshotProcessingIdleHarness: View {
    var body: some View {
        NavigationStack {
            ProcessingView(
                video: SelectedVideo(
                    assetIdentifier: "screenshot",
                    asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                    duration: 60),
                autostart: false,
                destination: { _, _ in EmptyView() })
        }
    }
}

/// Scripted `ProcessingRunning` for the harness: one mid-run progress report, then hold.
private struct ScreenshotProcessingRunner: ProcessingRunning {
    func run(
        video: SelectedVideo,
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

// MARK: - Pose diagnostic

/// Pose diagnostic before a run (`-screenshotPoseDiagnostic`): the video length and
/// the "Run diagnostic" button. No inference runs until the button is tapped, so the
/// initial state needs neither the model nor a real video file.
struct ScreenshotPoseDiagnosticHarness: View {
    var body: some View {
        NavigationStack {
            PoseDiagnosticView(
                video: SelectedVideo(
                    assetIdentifier: "screenshot",
                    asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                    duration: 12))
        }
    }
}
#endif
