import AVFoundation
import Foundation

/// One kept clip handed to the confirmation screen: its trick window and the static crop
/// rect for it (docs/DESIGN.md's pipeline steps 5-6).
///
/// Built only on main-branch types (`TrickWindow`, `NormalizedRect`) so this screen
/// compiles standalone: the clip list maps its kept items onto these, and the exporter
/// maps these onto `ClipSpec`.
struct ExportConfirmationItem: Identifiable, Sendable {
    let id: UUID
    let window: TrickWindow
    let cropRect: NormalizedRect

    init(id: UUID = UUID(), window: TrickWindow, cropRect: NormalizedRect) {
        self.id = id
        self.window = window
        self.cropRect = cropRect
    }
}

/// Names which of one clip's two independently-failable steps broke: export and the
/// Photos-library write fail independently per clip (e.g. Photos permission revoked
/// mid-flow — `docs/UIUX.md` § "Export Confirmation"), and the fix differs, so the
/// summary's per-clip callout names the step rather than just the clip.
enum ExportConfirmationError: Error, Equatable {
    case exportFailed(reason: String)
    case photosSaveFailed(reason: String)
}

/// Exports one kept clip: trims and crops the source video, writes the file into
/// `directory`, and returns its URL. Reports the export's 0.0–1.0 progress; the Photos
/// save has no progress of its own, so the screen shows its own "saving" state around
/// the save step instead.
///
/// A closure rather than a protocol so the screen's only seam is one value: the clip
/// exporter plugs in here with a small adapter, and tests inject a fake. Throws
/// `ExportConfirmationError.exportFailed` (not a raw error) so the failure callout
/// can name the step.
///
/// Concurrency contract: this closure is awaited from the run task, which inherits
/// `@MainActor` isolation, so it starts executing on the main actor's executor —
/// implementations must not block the calling executor. Do CPU-bound or blocking work
/// off the main actor internally (e.g. `Task.detached`) and hop back only for the
/// progress callback. `@Sendable` constrains what the closure captures, not where it
/// executes.
typealias ExportOneClip = @Sendable (
    _ window: TrickWindow,
    _ cropRect: NormalizedRect,
    _ asset: AVAsset,
    _ directory: URL,
    _ progress: @escaping @Sendable (Double) -> Void
) async throws -> URL

/// Saves one exported file to the Photos library. `ClipPhotosSaver` plugs in here.
/// Throws `ExportConfirmationError.photosSaveFailed` so the callout names
/// the step.
///
/// Concurrency contract: awaited from the run task, which inherits `@MainActor`
/// isolation — implementations must not block the calling executor; hop off the main
/// actor internally for any blocking work.
typealias SaveOneClipToPhotos = @Sendable (URL) async throws -> Void

/// The name prefix for every export scratch directory. The stale-directory sweep
/// below removes only directories carrying this prefix; anything else sharing the
/// parent folder is left alone.
let exportDirectoryNamePrefix = "turnip-export-"

/// The scratch directory for one export screen: a fresh UUID-named folder under the
/// app's temp directory, so repeated visits never share outputs. The screen deletes it
/// in `tearDown()`. Internal so tests can pass their own directory and assert on the
/// lifecycle without touching the real tmp dir.
func defaultExportDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(exportDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
}

/// Best-effort sweep of orphaned export scratch directories. A killed screen never
/// executes `tearDown()`, so its scratch directory is left behind; each new screen
/// removes those stale siblings before making its own. Skips
/// `excluding` (this run's about-to-be-created directory), touches only
/// directories whose name carries `exportDirectoryNamePrefix`, and swallows every
/// failure — leftover scratch is untidy but bounded (the OS purges tmp under
/// pressure), so a sweep failure must never fail the run.
func sweepStaleExportDirectories(in parentDirectory: URL, excluding current: URL) {
    let candidates = (try? FileManager.default.contentsOfDirectory(
        at: parentDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    for candidate in candidates {
        guard candidate != current,
              candidate.lastPathComponent.hasPrefix(exportDirectoryNamePrefix),
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { continue }
        try? FileManager.default.removeItem(at: candidate)
    }
}

/// The export confirmation screen's state machine (`docs/UIUX.md` § "Export
/// Confirmation").
///
/// Drives one clip at a time through export → Photos save, publishing per-clip phases so
/// the view shows live progress, and ends in a summary: "N of M clips saved to Photos"
/// with any per-clip failures named individually rather than folded into a count. One
/// clip's failure never aborts the rest — a bad window in a multi-trick recording must
/// not cost the clips around it. Each exported clip's file URL is published alongside its
/// phase so the screen can offer it to the system share sheet (`docs/DESIGN.md`
/// § "Publishing to social media (iOS Share Sheet)"); the scratch directory's lifetime is
/// therefore the screen's, not the run's.
///
/// `@MainActor` throughout: the published phases are read by SwiftUI on the main thread,
/// and the run task inherits that isolation, so the injected closures start on the main
/// actor's executor — the AVFoundation/Photos work inside them must hop off the main
/// actor internally rather than block it (see the typealias contracts). Cancellation is
/// cooperative — the in-flight step stops on its own (the
/// export session cancels via its cancellation handler), the loop checks between clips,
/// remaining clips stay `.pending`, and the partial summary is honest about what actually
/// saved. A start after cancel restarts cleanly: the new run waits for the old one to
/// drain, resets the cancellation flag and unfinished phases, and skips clips already
/// saved — the same video is never written to Photos twice.
@MainActor
final class ExportConfirmationViewModel: ObservableObject {
    /// One clip's visible state on the confirmation screen.
    struct ClipState: Identifiable, Equatable {
        let id: UUID
        /// "Clip 1 · 2.4s" — the number is the export order, the duration the window's.
        let title: String
        var phase: Phase
        /// Where the export wrote this clip, once the export step succeeded. Kept
        /// rather than discarded after the Photos save because the share sheet hands
        /// the system the file itself: the URL has to stay valid for as long as the
        /// row can be shared.
        var fileURL: URL?

        /// The URL the row's Share action hands to the system share sheet, or `nil`
        /// when there is nothing to hand off.
        ///
        /// A clip whose Photos save failed still offers it: the file exists, and
        /// sharing it to Messages or AirDrop is the way out of a revoked Photos
        /// permission. A clip still exporting or saving does not — the file is only
        /// complete once the export step returns.
        var shareURL: URL? {
            switch phase {
            case .saved, .failed:
                return fileURL
            case .pending, .exporting, .saving:
                return nil
            }
        }
    }

    /// The per-clip export phase. `.saving` covers the Photos write, which reports no
    /// progress of its own — the screen shows an indeterminate spinner there.
    enum Phase: Equatable {
        case pending
        case exporting(fraction: Double)
        case saving
        case saved
        case failed(reason: String)
    }

    @Published private(set) var clips: [ClipState]
    @Published private(set) var isFinished = false
    @Published private(set) var wasCancelled = false
    /// Stored (not derived from `runTask`) so `start()`/`cancel()` publish and the
    /// view re-renders: the Cancel item appears when the run starts and leaves when
    /// it ends.
    @Published private(set) var isRunning = false

    /// The result summary, in `docs/UIUX.md`'s exact shape. `nil` until the run ends —
    /// the summary counts saved clips, and nothing is saved until the loop reports it.
    var summaryText: String? {
        guard isFinished else { return nil }
        let savedCount = clips.filter { $0.phase == .saved }.count
        let noun = clips.count == 1 ? "clip" : "clips"
        let prefix = wasCancelled ? "Export cancelled — " : ""
        return "\(prefix)\(savedCount) of \(clips.count) \(noun) saved to Photos"
    }

    /// Per-clip failures for the summary's individual callouts: the title names the clip,
    /// the reason names the failed step.
    var failures: [(title: String, reason: String)] {
        clips.compactMap { clip in
            guard case .failed(let reason) = clip.phase else { return nil }
            return (clip.title, reason)
        }
    }

    private let items: [ExportConfirmationItem]
    private let asset: AVAsset
    private let exportClip: ExportOneClip
    private let saveToPhotos: SaveOneClipToPhotos
    private let makeDirectory: @Sendable () -> URL
    /// The screen's scratch directory, made on the first run and reused by a restart.
    /// `nil` until a run has prepared it, and again after `tearDown()`.
    private var directory: URL?
    /// The teardown's deletion, held rather than discarded so the removal is
    /// awaitable — it only runs once the cancelled run has drained.
    private(set) var cleanupTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// Set by `cancel()` and cleared when a run actually ends or a newer run starts:
    /// distinguishes "a run is in flight" from "a cancelled run is still draining", so
    /// `start()` ignores the view's `.task` re-fire during a live run but restarts —
    /// after the drain — once the user cancelled.
    private var cancelRequested = false
    /// Monotonic run id. `start()` bumps it and the run's task captures the value; the
    /// trailing teardown only ends the screen when its captured id still matches, so a
    /// still-draining older run can't clear a newer run's handle, flip `isFinished`
    /// under it, or leak its cancellation flag into the new run's summary.
    private var generation: UInt64 = 0

    init(
        items: [ExportConfirmationItem],
        asset: AVAsset,
        exportClip: @escaping ExportOneClip,
        saveToPhotos: @escaping SaveOneClipToPhotos,
        makeDirectory: @escaping @Sendable () -> URL = defaultExportDirectory
    ) {
        self.items = items
        self.clips = items.enumerated().map { index, item in
            let duration = ClipDurationFormatter.string(
                from: item.window.endTime - item.window.startTime)
            return ClipState(
                id: item.id,
                title: "Clip \(index + 1) · \(duration)",
                phase: .pending)
        }
        self.asset = asset
        self.exportClip = exportClip
        self.saveToPhotos = saveToPhotos
        self.makeDirectory = makeDirectory
    }

    /// Starts the export run.
    ///
    /// - Parameter userInitiated: pass `true` only when the start comes from an
    ///   explicit user gesture (a retry control, once one exists). The view's `.task`
    ///   re-fires on every re-appear and calls `start()` without it, so re-appear
    ///   starts the first run but can never resurrect a cancelled one.
    ///
    /// Ignored while a live run is in flight and once a run has finished — the screen
    /// shows one run. A user-initiated start after `cancel()` is a genuine restart: the
    /// new run first waits for the cancelled run to drain, then the cancellation flag
    /// clears, unfinished clips go back to `.pending`, and clips already `.saved` stay
    /// saved and are skipped — so the new run never writes the same video to Photos
    /// twice. Bumps the generation so the trailing teardown below belongs to exactly
    /// this run (see `generation`).
    func start(userInitiated: Bool = false) {
        guard !isFinished else { return }
        // A `.task` re-fire (re-appear) may only start the first run: once a run has
        // begun, only an explicit user gesture may start another. Without this, the
        // re-appear after `cancel()` — the view cancels on disappear — would resurrect
        // the cancelled run while it is still draining.
        if !userInitiated, generation > 0 { return }
        // A live run owns the screen: the view's `.task` re-fires on re-appear and
        // must not disturb it. A cancelled-but-draining run doesn't block a
        // user-initiated restart — the new task waits for it below before touching
        // any clip.
        if runTask != nil, !cancelRequested { return }
        generation &+= 1
        let runGeneration = generation
        let previousRun = runTask
        cancelRequested = false
        isRunning = true
        // A restart is a clean slate, not a continuation: the previous run's
        // cancellation must not taint this run's summary, and every unfinished clip
        // goes back to `.pending`. Clips already `.saved` keep their phase and are
        // skipped by the loop below.
        wasCancelled = false
        for index in clips.indices where clips[index].phase != .saved {
            clips[index].phase = .pending
            // This clip is about to be exported again, so its previous output is
            // superseded: drop the URL rather than offer a Share action for a file
            // the new run is replacing.
            clips[index].fileURL = nil
        }
        // The run task inherits `@MainActor` isolation, so the run — including the
        // injected closures — starts on the main actor's executor. The closures must
        // hop off internally rather than block it (see the typealias contracts).
        runTask = Task { [weak self] in
            await self?.runExport(generation: runGeneration, previousRun: previousRun)
        }
    }

    /// The body of one export run: serializes with the previous run, prepares the
    /// scratch directory, drives each clip through export → Photos save, then tears
    /// the screen down. Extracted from `start()` so the entry point stays small.
    private func runExport(generation runGeneration: UInt64, previousRun: Task<Void, Never>?) async {
        // Serialize with the previous run: after `cancel()` it can still be
        // draining cooperatively. Waiting here — before any phase write or side
        // effect — means two runs never interleave exports or Photos writes, so the
        // skip-`.saved` check below can't race the old run's in-flight save.
        await previousRun?.value
        let directory = prepareDirectory()
        var runWasCancelled = false
        for (index, item) in items.enumerated() {
            let shouldContinue = await exportClipItem(
                at: index, item: item, directory: directory)
            if !shouldContinue {
                // Cancellation is per-run: only the newest run's teardown publishes
                // the flag, so a superseded run can't taint the new run's summary.
                runWasCancelled = true
                break
            }
        }
        finishRun(generation: runGeneration, wasCancelled: runWasCancelled)
    }

    /// The screen's scratch directory, created on first use.
    ///
    /// One directory per screen rather than per run: a restart exporting into the
    /// same directory is what keeps an already-saved clip's file — and so its Share
    /// action — alive across the restart. `tearDown()` deletes it.
    private func prepareDirectory() -> URL {
        if let directory { return directory }
        let directory = makeDirectory()
        // A killed screen never executes `tearDown()`, orphaning its scratch
        // directory: sweep stale `turnip-export-*` siblings before making this
        // one, so repeated kills can't accumulate temp dirs.
        sweepStaleExportDirectories(
            in: directory.deletingLastPathComponent(), excluding: directory)
        // The exporter writes into this directory; it must exist before the first
        // export session starts. A failure here surfaces per clip from the export
        // step — tmp creation all but never fails, so there is no dedicated state
        // for it.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        self.directory = directory
        return directory
    }

    /// Drives one clip through export → Photos save, publishing its phases.
    /// Returns false when the run must stop: the task was cancelled, either before
    /// the clip started or by whatever the in-flight step threw. The cancelled
    /// task — not the error type — decides, so the in-flight clip goes back to
    /// `.pending` instead of keeping a dead `Exporting… N%` progress bar on the
    /// finished summary (issue #132). Any other error fails just this clip and the
    /// run continues with the next one.
    private func exportClipItem(
        at index: Int, item: ExportConfirmationItem, directory: URL
    ) async -> Bool {
        if Task.isCancelled { return false }
        // A clip the previous run already saved stays saved: re-running the
        // loop must not write the same video to Photos twice.
        if clips.indices.contains(index), clips[index].phase == .saved { return true }
        setPhase(at: index, to: .exporting(fraction: 0))
        do {
            let fileURL = try await exportClip(
                item.window, item.cropRect, asset, directory
            ) { [weak self] fraction in
                Task { [weak self] in
                    await self?.reportExportProgress(index: index, fraction: fraction)
                }
            }
            setFileURL(at: index, to: fileURL)
            setPhase(at: index, to: .saving)
            try await saveToPhotos(fileURL)
            setPhase(at: index, to: .saved)
        } catch {
            if Task.isCancelled {
                // The run was cancelled while this clip was in flight: the clip
                // was never written, so `.pending` — not `.failed` — is the
                // honest phase, matching the contract that cancelled runs keep
                // clips pending. Reset before returning so the finished summary
                // doesn't keep a dead `Exporting… N%` progress bar (issue #132).
                setPhase(at: index, to: .pending)
                return false
            }
            setPhase(at: index, to: .failed(reason: Self.reason(for: error)))
        }
        return true
    }

    /// Ends the run on screen. Only the newest run may end the screen: a cancelled
    /// run's task can still be draining when a newer run starts, so a stale teardown
    /// must not clear the new run's handle, flip `isFinished` under it, drop
    /// `isRunning` while the newer run is still going, or publish its cancellation
    /// flag into the new run's summary.
    private func finishRun(generation runGeneration: UInt64, wasCancelled runWasCancelled: Bool) {
        guard generation == runGeneration else { return }
        wasCancelled = runWasCancelled
        isFinished = true
        isRunning = false
        cancelRequested = false
        runTask = nil
    }

    /// Ends the screen: cancels the run and deletes the scratch directory once the
    /// cancelled run has drained. The view calls this on disappear.
    ///
    /// Deleting here rather than when the run ends is what makes the Share action
    /// possible — the share sheet hands the system a file URL, so every exported file
    /// has to outlive its run and stay on disk while its row is on screen. Waiting for
    /// the drain means the deletion never races an export still writing into the
    /// directory, and the URLs are cleared first so no row offers a file that is on its
    /// way out.
    func tearDown() {
        cancel()
        let draining = runTask
        let removing = directory
        directory = nil
        for index in clips.indices {
            clips[index].fileURL = nil
        }
        cleanupTask = Task.detached {
            await draining?.value
            guard let removing else { return }
            try? FileManager.default.removeItem(at: removing)
        }
    }

    /// Cancels the run. Cooperative: the in-flight step stops on its own and remaining
    /// clips stay `.pending`. The handle is kept rather than nilled so a subsequent
    /// `start()` can wait for the drain before restarting. Leaves the scratch directory
    /// alone — a cancelled run's already-exported clips stay shareable until the screen
    /// itself goes away (`tearDown()`).
    func cancel() {
        cancelRequested = true
        runTask?.cancel()
    }

    /// Applies one export progress tick. Only while the clip is still `.exporting` —
    /// ticks can arrive after the phase moved on (the export session reports 1.0 as it
    /// goes terminal), and a stale write must not clobber `.saving` / `.saved` / `.failed`.
    /// Each tick hops to the main actor on its own unstructured task, so ticks can land
    /// out of order — the phase keeps the max, so the progress bar never moves backwards.
    private func reportExportProgress(index: Int, fraction: Double) {
        guard clips.indices.contains(index),
              case .exporting(let current) = clips[index].phase
        else { return }
        clips[index].phase = .exporting(fraction: max(current, min(max(fraction, 0), 1)))
    }

    private func setFileURL(at index: Int, to fileURL: URL) {
        guard clips.indices.contains(index) else { return }
        clips[index].fileURL = fileURL
    }

    private func setPhase(at index: Int, to phase: Phase) {
        guard clips.indices.contains(index) else { return }
        clips[index].phase = phase
    }

    /// The failure callout for one clip. Adapters throw `ExportConfirmationError` to get
    /// the failed step named; anything else falls back to its localized description.
    private static func reason(for error: Error) -> String {
        switch error {
        case ExportConfirmationError.exportFailed(let reason):
            return "Export failed — \(reason)"
        case ExportConfirmationError.photosSaveFailed(let reason):
            return "Couldn't save to Photos — \(reason)"
        default:
            return error.localizedDescription
        }
    }
}
