import AVFoundation
import Foundation

/// One kept clip handed to the confirmation screen: its trick window and the static crop
/// rect for it (docs/DESIGN.md's pipeline steps 5-6).
///
/// Built only on main-branch types (`TrickWindow`, `NormalizedRect`) so this screen
/// compiles without the clip list (#11) or the clip exporter (#10) — the same
/// standalone-contract convention as the clip editor's `ClipEditorSource`. The list maps
/// its kept items onto these, and the exporter maps these onto `ClipSpec`, when the
/// wiring PR lands.
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
/// A closure rather than a protocol so the screen's only seam is one value: `ClipExporter`
/// (#10) plugs in here with a small adapter when it merges, and tests inject a fake.
/// Throws `ExportConfirmationError.exportFailed` (not a raw error) so the failure callout
/// can name the step. `@Sendable` because the exporter runs it off the main actor.
typealias ExportOneClip = @Sendable (
    _ window: TrickWindow,
    _ cropRect: NormalizedRect,
    _ asset: AVAsset,
    _ directory: URL,
    _ progress: @Sendable (Double) -> Void
) async throws -> URL

/// Saves one exported file to the Photos library. `ClipPhotosSaver` (#10) plugs in here
/// when it merges. Throws `ExportConfirmationError.photosSaveFailed` so the callout names
/// the step.
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
/// Confirmation", issue #19).
///
/// Drives one clip at a time through export → Photos save, publishing per-clip phases so
/// the view shows live progress, and ends in a summary: "N of M clips saved to Photos"
/// with any per-clip failures named individually rather than folded into a count. One
/// clip's failure never aborts the rest — a bad window in a multi-trick recording must
/// not cost the clips around it.
///
/// `@MainActor` throughout: the published phases are read by SwiftUI on the main thread,
/// and the AVFoundation/Photos work stays inside the injected closures, which run off the
/// main actor. Cancellation is cooperative — the in-flight step stops on its own (the
/// export session cancels via its cancellation handler), the loop checks between clips,
/// remaining clips stay `.pending`, and the partial summary is honest about what actually
/// saved.
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

    var isRunning: Bool { runTask != nil }

    private let items: [ExportConfirmationItem]
    private let asset: AVAsset
    private let exportClip: ExportOneClip
    private let saveToPhotos: SaveOneClipToPhotos
    private let makeDirectory: @Sendable () -> URL
    private var runTask: Task<Void, Never>?

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

    /// Starts the export run. Ignored while a run is in flight and once a run has
    /// finished — the screen shows one run, and the view's `.task` re-fires on
    /// re-appear, which must not re-export.
    func start() {
        guard runTask == nil, !isFinished else { return }
        // Captured up front: the loop below runs off the main actor, and `self` is only
        // ever touched through `MainActor.run`.
        let items = self.items
        let asset = self.asset
        let exportClip = self.exportClip
        let saveToPhotos = self.saveToPhotos
        let makeDirectory = self.makeDirectory
        runTask = Task { [weak self] in
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
                // directory and the sandbox must not accumulate them (issue #23).
                try? FileManager.default.removeItem(at: directory)
            }
            for (index, item) in items.enumerated() {
                if Task.isCancelled {
                    await MainActor.run { [weak self] in self?.wasCancelled = true }
                    break
                }
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
                        await MainActor.run { [weak self] in self?.wasCancelled = true }
                        break
                    }
                    await MainActor.run { [weak self] in
                        self?.setPhase(at: index, to: .failed(reason: Self.reason(for: error)))
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.isFinished = true
                self?.runTask = nil
            }
        }
    }

    /// Cancels the run. Cooperative: the in-flight step stops on its own, remaining clips
    /// stay `.pending`, and the scratch directory is still cleaned up by `start()`'s
    /// `defer`. The view calls this on disappear, so a run never outlives its screen.
    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    /// Applies one export progress tick. Only while the clip is still `.exporting` —
    /// ticks can arrive after the phase moved on (the export session reports 1.0 as it
    /// goes terminal), and a stale write must not clobber `.saving` / `.saved` / `.failed`.
    private func reportExportProgress(index: Int, fraction: Double) {
        guard clips.indices.contains(index),
              case .exporting = clips[index].phase
        else { return }
        clips[index].phase = .exporting(fraction: min(max(fraction, 0), 1))
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
    /// clip number. Duplicated from the clip list's label rather than shared: that code
    /// ships in the unmerged #11 PR (the same convention as the clip editor's geometry
    /// helpers); the two should converge once both land.
    private static func durationLabel(for window: TrickWindow) -> String {
        let tenths = ((window.endTime - window.startTime) * 10).rounded() / 10
        return "\(tenths)s"
    }
}
