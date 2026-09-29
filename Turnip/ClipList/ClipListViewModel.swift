import AVFoundation
import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// Exports one clip: trims the source video to the window, crops to its rect, and
/// writes an `.mp4` into `directory`. Failures surface as `ClipSaveError.exportFailed`
/// so a save failure names the step; cancellation propagates untouched.
///
/// A closure rather than a protocol so `ClipListViewModel`'s only seam is one value:
/// the real clip exporter plugs in here with a small adapter, and tests inject a
/// fake.
///
/// Concurrency contract: awaited from `ClipListViewModel.save()`, which is
/// `@MainActor`-isolated, so this starts executing on the main actor's executor —
/// implementations must not block the calling executor. Do CPU-bound or blocking
/// work off the main actor internally (e.g. `Task.detached`).
typealias ExportOneClip = @Sendable (
    _ spec: ClipSpec,
    _ asset: AVAsset,
    _ directory: URL,
    _ progress: @escaping @Sendable (Double) -> Void
) async throws -> URL

/// Saves one exported file to the Photos library. `ClipPhotosSaver` plugs in here.
/// Throws `ClipSaveError.photosSaveFailed` so a save failure names the step. `albumTitle` is
/// the Settings screen's "Save to an album" destination (`TurnipSettings.albumDestination`),
/// read once by `save()` and threaded through rather than read again per clip.
///
/// Concurrency contract: same as `ExportOneClip` — awaited from `@MainActor`-isolated
/// code, so implementations must hop off the main actor internally for blocking work.
typealias SaveOneClipToPhotos = @Sendable (_ fileURL: URL, _ albumTitle: String?) async throws -> Void

/// Deletes the original video from Photos by its `PHAsset.localIdentifier`.
/// `PhotoAssetDeleter` plugs in here. A throw here is treated as non-fatal by
/// `save()` — the original staying in the library is the safe outcome of a decline
/// or a revoked permission, not a reportable failure.
typealias DeleteOriginalAsset = @Sendable (String) async throws -> Void

/// Names which of a clip's two independently-failable steps broke: export and the
/// Photos-library write fail independently (e.g. Photos permission revoked
/// mid-save), and the fix differs, so the failure message names the step.
enum ClipSaveError: Error, Equatable {
    case exportFailed(reason: String)
    case photosSaveFailed(reason: String)
}

/// The name prefix for every save-run scratch directory. The stale-directory sweep
/// below removes only directories carrying this prefix; anything else sharing the
/// parent folder is left alone.
let exportDirectoryNamePrefix = "turnip-export-"

/// A fresh UUID-named scratch directory under the app's temp directory for one
/// `save()` run. `save()` removes it once every clip has exported and saved (or
/// failed) — nothing needs to outlive the run, since there is no share sheet here.
@Sendable func defaultExportDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(exportDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
}

/// Best-effort sweep of orphaned save-run scratch directories. A killed screen never
/// finishes its run, so its scratch directory is left behind; each new run removes
/// those stale siblings before making its own. Skips `excluding` (this run's
/// about-to-be-created directory), touches only directories whose name carries
/// `exportDirectoryNamePrefix`, and swallows every failure — leftover scratch is
/// untidy but bounded (the OS purges tmp under pressure), so a sweep failure must
/// never fail the run.
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

/// The production `ExportOneClip`, wired to the real pipeline step 7 (`ClipExporter`).
private func exportOneClip(
    _ spec: ClipSpec, _ asset: AVAsset, _ directory: URL,
    _ progress: @escaping @Sendable (Double) -> Void
) async throws -> URL {
    do {
        let exported = try await ClipExporter().export(
            spec, from: asset, to: directory, progress: progress)
        return exported.fileURL
    } catch {
        if error is CancellationError { throw error }
        throw ClipSaveError.exportFailed(reason: error.localizedDescription)
    }
}

/// The production `SaveOneClipToPhotos`, wired to `ClipPhotosSaver` (add-only
/// authorization).
private func saveOneClipToPhotos(_ url: URL, albumTitle: String?) async throws {
    do {
        try await ClipPhotosSaver().saveVideo(at: url, albumTitle: albumTitle)
    } catch {
        throw ClipSaveError.photosSaveFailed(reason: error.localizedDescription)
    }
}

/// The production `DeleteOriginalAsset`, wired to `PhotoAssetDeleter`.
private func deleteOriginalVideo(_ assetIdentifier: String) async throws {
    try await PhotoAssetDeleter().delete(assetIdentifier: assetIdentifier)
}

/// Backing store for `ClipListView` (`docs/UIUX.md` § "Clip List (triage)").
@MainActor
final class ClipListViewModel: ObservableObject {
    @Published private(set) var items: [ClipListItem]
    /// True while `save()` is exporting/saving clips and possibly deleting the
    /// original — the screen shows a spinner and disables its content for this.
    @Published private(set) var isSaving = false
    /// Set by `save()` when a clip failed and cleared once the screen's alert
    /// dismisses. `nil` means no alert is showing.
    @Published var saveFailureMessage: String?

    /// The item fields a decoded thumbnail actually depends on — `isTrashed` isn't
    /// here, since trashing a clip never changes what its preview frame looks like.
    /// Tagging cache entries with this, rather than clearing the cache from every call
    /// site that can mutate an item, makes the cache self-invalidating: a decode
    /// started before an edit and delivered after it carries the *pre-edit* key, so it
    /// can never read back as current for the *post-edit* item, however the two race.
    private struct ThumbnailCacheKey: Equatable {
        let window: TrickWindow
        let cropRect: NormalizedRect
        let cropAdjustment: CropAdjustment
    }

    /// Decoded thumbnails by item id, each tagged with the key it was decoded from.
    /// Plain storage, not `@Published`: no view reads this dictionary — each card
    /// renders from its own `@State` thumbnail — so publishing it would re-evaluate
    /// every card's body on every completed decode.
    private var thumbnails: [UUID: (key: ThumbnailCacheKey, image: CGImage)] = [:]

    private let asset: AVAsset
    /// The source video's `PHAsset.localIdentifier`, for deleting it from Photos
    /// when the original tile is trashed at `save()` time.
    private let assetIdentifier: String
    private let loader: ClipThumbnailLoader
    /// One in-flight decode per id, tagged with the key it was started for — a caller
    /// only joins it when its own key still matches, so a request that arrives for a
    /// freshly-edited item never gets handed the pre-edit decode another caller is
    /// already waiting on.
    private var inFlight: [UUID: (key: ThumbnailCacheKey, task: Task<CGImage?, Never>)] = [:]
    private let exportClip: ExportOneClip
    private let saveToPhotos: SaveOneClipToPhotos
    private let deleteOriginalAsset: DeleteOriginalAsset
    private let makeDirectory: @Sendable () -> URL
    /// Read once per `save()` run for the album destination — injected (like
    /// `CameraCaptureViewModel`'s own `settingsProvider`) so a test can drive the album-on
    /// path without touching the real `UserDefaults.standard`-backed singleton. `@MainActor`-typed
    /// so the default value's closure literal, which reads the main-actor-isolated
    /// `TurnipSettingsStore.shared`, type-checks as a default argument.
    private let settingsProvider: @MainActor () -> TurnipSettings

    /// The asset's duration in seconds, loaded once per asset and shared by every
    /// card's inline trim timeline. `nil` when the asset can't be read — the timeline
    /// then hides itself rather than guessing a scale.
    private var durationTask: Task<TimeInterval?, Never>?

    /// The video track and its geometry, loaded once per asset and shared by every
    /// card's live preview composition (`videoComposition(cropRect:cropAdjustment:)`).
    private struct TrackGeometry {
        let track: AVAssetTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let frameRate: Float
    }
    private var trackGeometryTask: Task<TrackGeometry?, Never>?

    /// Prepends the original-video item to `items`: the invariant that
    /// `items[0]` always stands for the source video, enforced in one place rather
    /// than left to every call site to remember. `duration` seeds its full-video
    /// window; the original tile never opens the editor, so this never needs
    /// re-deriving.
    init(
        items: [ClipListItem],
        asset: AVAsset,
        assetIdentifier: String,
        duration: TimeInterval,
        loader: ClipThumbnailLoader = ClipThumbnailLoader(),
        exportClip: @escaping ExportOneClip = exportOneClip,
        saveToPhotos: @escaping SaveOneClipToPhotos = saveOneClipToPhotos,
        deleteOriginalAsset: @escaping DeleteOriginalAsset = deleteOriginalVideo,
        makeDirectory: @escaping @Sendable () -> URL = defaultExportDirectory,
        settingsProvider: @escaping @MainActor () -> TurnipSettings = { TurnipSettingsStore.shared.current }
    ) {
        let original = ClipListItem(
            window: TrickWindow(startTime: 0, endTime: max(duration, 0)),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            isOriginal: true)
        self.items = [original] + items
        self.asset = asset
        self.assetIdentifier = assetIdentifier
        self.loader = loader
        self.exportClip = exportClip
        self.saveToPhotos = saveToPhotos
        self.deleteOriginalAsset = deleteOriginalAsset
        self.makeDirectory = makeDirectory
        self.settingsProvider = settingsProvider
    }

    /// The analyzed asset, shared with the editor destination so it previews and
    /// exports from the same source the list's thumbnails were decoded from.
    var sourceAsset: AVAsset { asset }

    /// Builds the editor's input for one list item: its window, crop rect, and crop
    /// adjustment plus the analyzed asset. Trash stays the list's own decision — the
    /// editor no longer surfaces or edits it. Never called for the original item —
    /// its tile doesn't open the editor.
    ///
    /// `poseFrames` is empty — the pipeline's sampled frames don't reach the
    /// list yet (the Home → Processing wiring threads them through when it
    /// lands), so the editor keeps the pipeline-computed crop rect instead of
    /// re-deriving it when a trim handle drags outward past the original
    /// window. Trimming and the live crop preview both work; only the
    /// re-derivation for newly included frames waits on the frames.
    func editorSource(for item: ClipListItem) -> ClipEditorSource {
        ClipEditorSource(
            window: item.window,
            cropRect: item.cropRect,
            cropAdjustment: item.cropAdjustment,
            asset: asset,
            poseFrames: [])
    }

    /// Applies the editor's commit to the item with the given id: the window, crop rect,
    /// and crop adjustment the user left the editor with replace the list entry's, so
    /// trim/crop edits commit on back-navigation (docs/UIUX.md § "Clip Detail / Editor").
    /// The item's `isTrashed` carries over unchanged — the editor doesn't own that decision.
    /// A no-op for unknown ids — the item may have been removed by a re-run of detection,
    /// or deleted from the editor, while it was open.
    func applyEditorResult(_ result: ClipEditorResult, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = ClipListItem(
            id: id,
            window: result.window,
            cropRect: result.cropRect,
            cropAdjustment: result.cropAdjustment,
            isTrashed: items[index].isTrashed)
    }

    /// Removes the item with the given id entirely: the editor's Delete action, and
    /// — for a derived clip — also what the list's own trash button now routes to
    /// via `trash(_:)`, since a derived clip has no restore once trashed. The
    /// original item can never be removed this way — it can only be soft-trashed —
    /// since deleting a `PHAsset` needs `save()`'s confirmation-and-cleanup flow, not
    /// an in-memory removal. A no-op for unknown ids.
    func delete(_ id: UUID) {
        items.removeAll { $0.id == id && !$0.isOriginal }
        // The id is gone from `items` for good, so nothing will ever look these up
        // again — drop them rather than leaking one entry per deleted clip for the
        // life of the screen.
        thumbnails.removeValue(forKey: id)
        inFlight[id] = nil
    }

    /// Flips one item's reversible trash flag — the primitive `trash(_:)` composes
    /// for the original tile. A no-op for unknown ids — the card that fired it may
    /// have been removed by a re-run of detection.
    func toggleTrash(_ item: ClipListItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isTrashed.toggle()
    }

    /// The per-card trash button's action: the original tile's trash is reversible
    /// (`toggleTrash`, read by `save()` to decide whether to delete the source video
    /// from Photos), while a derived clip's trash removes its tile from the grid
    /// immediately (`delete(_:)`) — there is no restore for a derived clip once
    /// trashed.
    func trash(_ item: ClipListItem) {
        if item.isOriginal {
            toggleTrash(item)
        } else {
            delete(item.id)
        }
    }

    /// A write-through binding to one item, for a destination that edits a clip in place.
    /// Keyed by id on both ends rather than closing over an index: get and set resolve
    /// the item from the current list. `nil` when the id is no longer in the list.
    func binding(for id: UUID) -> Binding<ClipListItem>? {
        guard let current = items.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.items.first(where: { $0.id == id }) ?? current },
            set: { updated in
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[index] = updated
            }
        )
    }

    /// The "+" tile's action: appends a new clip covering the first few seconds of the
    /// asset (or its full duration if shorter), full-frame crop. The user trims it with
    /// the same inline timeline every other card uses; there's no separate creation UI.
    func addClip() async {
        let duration = await assetDuration() ?? Self.defaultNewClipDuration
        let end = max(min(Self.defaultNewClipDuration, duration), ClipEditorViewModel.minimumClipDuration)
        items.append(ClipListItem(
            window: TrickWindow(startTime: 0, endTime: end),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)))
    }

    private static let defaultNewClipDuration: TimeInterval = 3

    /// Loads the asset's duration once per asset; concurrent callers share the single
    /// in-flight task. `@MainActor`-serialized, so the check-then-set is race-free
    /// (same pattern as `trackGeometry()` below).
    func assetDuration() async -> TimeInterval? {
        if durationTask == nil {
            durationTask = Task { [asset] in
                guard let duration = try? await asset.load(.duration) else { return nil }
                let seconds = duration.seconds
                return seconds.isFinite && seconds > 0 ? seconds : nil
            }
        }
        guard let durationTask else { return nil }
        return await durationTask.value
    }

    /// Loads the source video track's natural size, preferred transform, and nominal
    /// frame rate once per asset; concurrent callers share the single in-flight task,
    /// same as `assetDuration()`. `nil` when the asset has no video track or its
    /// geometry can't be read.
    private func trackGeometry() async -> TrackGeometry? {
        if trackGeometryTask == nil {
            trackGeometryTask = Task { [asset] in
                guard let track = try? await asset.loadTracks(withMediaType: .video).first
                else { return nil }
                guard let naturalSize = try? await track.load(.naturalSize),
                      let preferredTransform = try? await track.load(.preferredTransform),
                      let frameRate = try? await track.load(.nominalFrameRate)
                else { return nil }
                return TrackGeometry(
                    track: track, naturalSize: naturalSize,
                    preferredTransform: preferredTransform, frameRate: frameRate)
            }
        }
        guard let trackGeometryTask else { return nil }
        return await trackGeometryTask.value
    }

    /// The live preview composition for one crop rect and crop adjustment, applied to the
    /// full (untrimmed) source track — `AVPlayerLooper`'s own `timeRange` already bounds
    /// what actually loops, this only shapes the frame. Built from the same
    /// `ClipExportTransform.make` the exported clip and the card's poster thumbnail both
    /// use, so the live-playing tile, the poster underneath it, and the saved clip always
    /// agree on the framing. `nil` when the track geometry can't be loaded or the crop
    /// rect is degenerate — the caller falls back to an uncomposed player rather than
    /// showing nothing.
    ///
    /// Takes the crop rect/adjustment directly rather than a `ClipListItem`: the caller
    /// (`ClipCardPlayback`) already resolves its target geometry away from the (possibly
    /// stale-`self`) item, and threading a whole `ClipListItem` through here would tempt a
    /// caller into rereading `item` itself for these two fields instead of passing the
    /// geometry it already resolved.
    func videoComposition(
        cropRect: NormalizedRect, cropAdjustment: CropAdjustment
    ) async -> AVVideoComposition? {
        guard let geometry = await trackGeometry(),
              let duration = try? await asset.load(.duration)
        else { return nil }
        guard let transform = ClipExportTransform.make(
            cropRect: cropRect, naturalSize: geometry.naturalSize,
            preferredTransform: geometry.preferredTransform, cropAdjustment: cropAdjustment)
        else { return nil }
        return transform.makeVideoComposition(
            for: geometry.track, duration: duration, frameRate: geometry.frameRate)
    }

    /// The card thumbnail, loading lazily. Idempotent and safe to call from every card's
    /// `.task`: repeat calls for an unchanged item return the cached image, and
    /// concurrent calls for the same item share one decode instead of seeking the same
    /// frame twice. The cache is keyed by the item's id *and* the fields the decoded
    /// frame depends on, so a call for the same id but a since-edited window/cropRect/
    /// cropAdjustment always re-decodes — including when it races a still-in-flight
    /// decode for the pre-edit item, which it never joins. A cancelled caller never
    /// cancels the shared decode — the decode runs to completion and the result is
    /// cached, so a card that scrolls off-screen and back within the decode window gets
    /// its thumbnail from the re-fired `.task` instead of a discarded, already-paid-for
    /// decode. (Lingering decodes are intentional: `copyCGImage` is not cancellable, so
    /// cancelling the shared task cannot save the expensive work — it can only throw the
    /// result away from under another waiter.)
    func thumbnail(for item: ClipListItem) async -> CGImage? {
        let key = ThumbnailCacheKey(
            window: item.window, cropRect: item.cropRect, cropAdjustment: item.cropAdjustment)
        if let cached = thumbnails[item.id], cached.key == key {
            return cached.image
        }
        if let running = inFlight[item.id], running.key == key {
            return await running.task.value
        }
        let task = Task { [loader, asset, item] in
            await loader.thumbnail(for: item, in: asset)
        }
        inFlight[item.id] = (key, task)
        let image = await task.value
        // Only clear the slot if it's still ours: a newer request for the same id may
        // have already raced past the checks above and installed its own in-flight
        // decode, which this stale completion must not clobber.
        if inFlight[item.id]?.key == key {
            inFlight[item.id] = nil
        }
        if let image = image {
            thumbnails[item.id] = (key, image)
        }
        return image
    }

    /// The "Done" action: exports and saves every non-trashed derived clip to
    /// Photos, then — only once every one of them has succeeded — deletes the
    /// original video from Photos if its tile was trashed. Returns `true` when the
    /// screen should pop to Home; `false` when a clip failed, in which case
    /// `saveFailureMessage` is set and the screen stays up so Done can be retried.
    ///
    /// The original is never deleted if any clip failed: deleting the source before
    /// every derived clip has confirmed safely landed in Photos would risk losing
    /// the user's only copy of a trick that never actually saved (the same lesson
    /// commit 4613460 drew from the camera's save flow). A failed original deletion
    /// (the user declined PhotoKit's own confirmation, or permission was revoked) is
    /// swallowed rather than surfaced — the original staying in the library is the
    /// safe outcome, not a reportable failure.
    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        let directory = makeDirectory()
        sweepStaleExportDirectories(in: directory.deletingLastPathComponent(), excluding: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Read once for the whole run rather than per clip: every clip in one Done tap saves to
        // the same destination, and a setting change mid-save shouldn't split a run across two
        // albums.
        let albumTitle = settingsProvider().albumDestination
        var failures: [String] = []
        for item in items where !item.isOriginal && !item.isTrashed {
            do {
                let spec = ClipSpec(
                    window: item.window, cropRect: item.cropRect, cropAdjustment: item.cropAdjustment)
                let fileURL = try await exportClip(spec, asset, directory) { _ in }
                try await saveToPhotos(fileURL, albumTitle)
            } catch {
                failures.append(Self.reason(for: error))
            }
        }
        guard failures.isEmpty else {
            saveFailureMessage = failures.joined(separator: "\n")
            return false
        }

        if let original = items.first(where: \.isOriginal), original.isTrashed {
            try? await deleteOriginalAsset(assetIdentifier)
        }
        return true
    }

    /// The failure message for one clip. Adapters throw `ClipSaveError` to get the
    /// failed step named; anything else falls back to its localized description.
    private static func reason(for error: Error) -> String {
        switch error {
        case ClipSaveError.exportFailed(let reason):
            return "Export failed — \(reason)"
        case ClipSaveError.photosSaveFailed(let reason):
            return "Couldn't save to Photos — \(reason)"
        default:
            return error.localizedDescription
        }
    }
}
