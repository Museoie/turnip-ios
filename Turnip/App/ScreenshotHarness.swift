#if DEBUG
import AVFoundation
import CoreVideo
import SwiftUI

/// UI-test screenshot harness for the export confirmation screen.
///
/// Shown only when the app is launched with `-screenshotExportConfirmation` (holds
/// the first clip mid-export at 50% so the screenshot shows the progress UI) or
/// `-screenshotExportConfirmationFinished` (the run completes instantly so the
/// screenshot shows the summary). Driven by `TurnipUITests/ScreenshotTests.swift`;
/// unreachable in normal use and compiled out of release builds.
struct ScreenshotHarness: View {
    let finishImmediately: Bool

    var body: some View {
        NavigationStack {
            ExportConfirmationView(
                items: [
                    ExportConfirmationItem(
                        window: TrickWindow(startTime: 2, endTime: 5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                    ExportConfirmationItem(
                        window: TrickWindow(startTime: 9, endTime: 11.5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
                ],
                asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                exportClip: { _, _, _, directory, progress in
                    if finishImmediately {
                        progress(1.0)
                    } else {
                        // Hold the run mid-export: the UI test screenshots the
                        // progress state, then the test runner kills the app.
                        progress(0.5)
                        try await Task.sleep(for: .seconds(60))
                    }
                    // A real (empty) file rather than a fabricated path: the Share
                    // action disables itself for a URL with nothing behind it, so a
                    // fake path would screenshot every row's action greyed out and
                    // leave the share sheet unreachable from the UI test.
                    let url = directory.appendingPathComponent(
                        "screenshot-clip-\(UUID().uuidString).mp4")
                    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
                    return url
                },
                saveToPhotos: { _ in }
            )
        }
    }
}

// MARK: - Home

/// Home's Photos-denied empty state (`-screenshotHome`).
///
/// The only Home state scriptable without the Photos library: the gallery grid needs
/// real `PHAsset`s, which have no public initializer, and launching the real `HomeView`
/// would raise the system permission prompt in the simulator. The denied state is pure
/// SwiftUI and deterministic.
struct ScreenshotHomeHarness: View {
    var body: some View {
        NavigationStack {
            PhotosAccessDeniedView(restricted: false)
                .navigationTitle("Turnip")
        }
    }
}

// MARK: - Clip list

/// Clip list triage (`-screenshotClipList`): three detected windows, one discarded.
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
                        isKept: false)
                ],
                asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")))
        }
    }
}

// MARK: - Clip editor

/// Clip editor (`-screenshotClipEditor`): the trimmed clip looping with its live crop
/// rect, the trim slider, and the keep toggle.
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
    private static let sampleMovieURL: URL = makeScreenshotSampleMovie()

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
                    isKept: true,
                    asset: AVURLAsset(url: Self.sampleMovieURL),
                    poseFrames: []),
                onCommit: { _ in })
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
                destination: { _ in EmptyView() })
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
