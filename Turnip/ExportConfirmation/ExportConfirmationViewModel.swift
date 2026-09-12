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

/// The scratch directory for one export run: a fresh UUID-named folder under the app's
/// temp directory, so repeated runs never share outputs. The run deletes it in
/// `start()`'s `defer`, whatever ended the run. Internal so tests can pass their own
/// directory and assert on the lifecycle without touching the real tmp dir.
func defaultExportDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("turnip-export-\(UUID().uuidString)", isDirectory: true)
}

/// The export confirmation screen's state machine (`docs/UIUX.md` § "Export
/// Confirmation").
///
/// Drives one clip at a time through export → Photos save, publishing per-clip phases so
/// the view shows live progress, and ends in a summary: "N of M clips saved to Photos"
/// with any per-clip failures named individually rather than folded into a count. One
/// clip's failure never aborts the rest — a bad window in a multi-trick recording must
/// not cost the clips around it.
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
            ClipState(
                id: item.id,
                title: "Clip \(index + 1) · \(Self.durationLabel(for: item.window))",
                phase: .pending)
        }
        self.asset = asset
        self.exportClip = exportClip
        self.saveToPhotos = saveToPhotos
        self.makeDirectory = makeDirectory
    }

    /// Starts the export run. Ignored while a live run is in flight and once a run has
    /// finished — the screen shows one run. A start after `cancel()` is a genuine
    /// restart: the new run first waits for the cancelled run to drain, then the
    /// cancellation flag clears, unfinished clips go back to `.pending`, and clips
    /// already `.saved` stay saved and are skipped — so the new run never writes the
    /// same video to Photos twice. Bumps the generation so the trailing teardown below
    /// belongs to exactly this run (see `generation`).
    func start() {
        guard !isFinished else { return }
        // A live run owns the screen: the view's `.task` re-fires on re-appear and
        // must not disturb it. A cancelled-but-draining run doesn't block a restart —
        // the new task waits for it below before touching any clip.
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
        }
        // Captured up front: the run task inherits `@MainActor` isolation, so the loop
        // below — including the injected closures — starts on the main actor's executor.
        // The closures must hop off internally rather than block it (see the typealias
        // contracts).
        let items = self.items
        let asset = self.asset
        let exportClip = self.exportClip
        let saveToPhotos = self.saveToPhotos
        let makeDirectory = self.makeDirectory
        runTask = Task { [weak self] in
            // Serialize with the previous run: after `cancel()` it can still be
            // draining cooperatively. Waiting here — before any phase write or side
            // effect — means two runs never interleave exports or Photos writes, so the
            // skip-`.saved` check below can't race the old run's in-flight save.
            await previousRun?.value
            let directory = makeDirectory()
            // The exporter writes into this directory; it must exist before the first
            // export session starts. A failure here surfaces per clip from the export
            // step — tmp creation all but never fails, so there is no dedicated state
            // for it.
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            defer {
                // Whatever ended the run, the scratch files go with it. The exporter
                // leaves failed outputs in place for debugging, but this screen owns the
                // directory and the sandbox must not accumulate them.
                try? FileManager.default.removeItem(at: directory)
            }
            // Cancellation is per-run: only the newest run's teardown publishes the
            // flag, so a superseded run can't taint the new run's summary.
            var runWasCancelled = false
            for (index, item) in items.enumerated() {
                if Task.isCancelled {
                    runWasCancelled = true
                    break
                }
                // A clip the previous run already saved stays saved: re-running the
                // loop must not write the same video to Photos twice.
                let alreadySaved = await MainActor.run { [weak self] in
                    self?.clips.indices.contains(index) == true
                        && self?.clips[index].phase == .saved
                }
                if alreadySaved { continue }
                await MainActor.run { [weak self] in
                    self?.setPhase(at: index, to: .exporting(fraction: 0))
                }
                do {
                    let fileURL = try await exportClip(
                        item.window, item.cropRect, asset, directory
                    ) { fraction in
                        Task {
                            await MainActor.run { [weak self] in
                                self?.reportExportProgress(index: index, fraction: fraction)
                            }
                        }
                    }
                    await MainActor.run { [weak self] in
                        self?.setPhase(at: index, to: .saving)
                    }
                    try await saveToPhotos(fileURL)
                    await MainActor.run { [weak self] in
                        self?.setPhase(at: index, to: .saved)
                    }
                } catch {
                    // Cancellation surfaces as whatever the in-flight step threw (the
                    // export session resumes with its own cancelled error, not
                    // `CancellationError`), so the cancelled task — not the error type —
                    // decides: cancelled stops the run, anything else fails the clip.
                    if Task.isCancelled {
                        runWasCancelled = true
                        break
                    }
                    await MainActor.run { [weak self] in
                        self?.setPhase(at: index, to: .failed(reason: Self.reason(for: error)))
                    }
                }
            }
            await MainActor.run { [weak self] in
                // Only the newest run may end the screen. A cancelled run's task can
                // still be draining when a newer run starts, so a stale teardown must
                // not clear the new run's handle, flip `isFinished` under it, drop
                // `isRunning` while the newer run is still going, or publish its
                // cancellation flag into the new run's summary.
                guard self?.generation == runGeneration else { return }
                self?.wasCancelled = runWasCancelled
                self?.isFinished = true
                self?.isRunning = false
                self?.cancelRequested = false
                self?.runTask = nil
            }
        }
    }

    /// Cancels the run. Cooperative: the in-flight step stops on its own, remaining clips
    /// stay `.pending`, and the scratch directory is still cleaned up by `start()`'s
    /// `defer`. The handle is kept rather than nilled so a subsequent `start()` can wait
    /// for the drain before restarting; the view calls this on disappear, so a run never
    /// outlives its screen.
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

    /// "2.4s"-style duration, built by hand so the decimal separator can't follow the
    /// device locale — a German-locale "2,4s" would read as a list separator next to the
    /// clip number.
    private static func durationLabel(for window: TrickWindow) -> String {
        let tenths = ((window.endTime - window.startTime) * 10).rounded() / 10
        // Whole seconds render as "3s", not "3.0s" — the fractional form reads like
        // a precision claim next to the "2.4s"-style labels elsewhere.
        if tenths == tenths.rounded() {
            return "\(Int(tenths))s"
        }
        return "\(tenths)s"
    }
}
