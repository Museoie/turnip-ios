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

/// Saves one exported file to the Photos library and returns the new asset's
/// `PHAsset.localIdentifier`, which the clip library keeps. `ClipPhotosSaver` plugs in here.
/// Throws `ClipSaveError.photosSaveFailed` so a save failure names the step. `albumTitle` is
/// the Settings screen's "Save to an album" destination (`TurnipSettings.albumDestination`),
/// read once by `save()` and threaded through rather than read again per clip.
///
/// Concurrency contract: same as `ExportOneClip` — awaited from `@MainActor`-isolated
/// code, so implementations must hop off the main actor internally for blocking work.
typealias SaveOneClipToPhotos = @Sendable (_ fileURL: URL, _ albumTitle: String?) async throws -> String

/// Writes a save into the on-device clip library and returns the achievements it earned.
/// `recordInClipLibrary` plugs in here.
typealias RecordSavedClips = @MainActor (LibrarySave) -> [EarnedAchievement]

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
private func saveOneClipToPhotos(_ url: URL, albumTitle: String?) async throws -> String {
    do {
        return try await ClipPhotosSaver().saveVideo(at: url, albumTitle: albumTitle)
    } catch {
        throw ClipSaveError.photosSaveFailed(reason: error.localizedDescription)
    }
}

/// Backing store for Name Clips (`NameClipsView`, `docs/UIUX.md` § "Name Clips"): the video's
/// clips with their windows, framing and save state, and the names given them. `items[0]`
/// stands for the source video itself: never one of the clips, its window carries the video's
/// Photos duration until the asset's own has loaded.
@MainActor
final class ClipListViewModel: ObservableObject {
    @Published private(set) var items: [ClipListItem]
    /// True while `save()` is exporting and saving clips — the screen shows a spinner and
    /// disables its content for this.
    @Published private(set) var isSaving = false
    /// Set by `save()` when a clip failed and cleared once the screen's alert
    /// dismisses. `nil` means no alert is showing.
    @Published var saveFailureMessage: String?

    /// The item fields a decoded thumbnail actually depends on. Tagging cache entries with
    /// this, rather than clearing the cache from every call site that can mutate an item,
    /// makes the cache self-invalidating: a decode started before an edit and delivered after
    /// it carries the *pre-edit* key, so it can never read back as current for the
    /// *post-edit* item, however the two race.
    private struct ThumbnailCacheKey: Equatable {
        let window: TrickWindow
        let cropRect: NormalizedRect
        let followCrop: FollowCrop?
    }

    /// Decoded thumbnails by item id, each tagged with the key it was decoded from.
    /// Plain storage, not `@Published`: no view reads this dictionary — each card
    /// renders from its own `@State` thumbnail — so publishing it would re-evaluate
    /// every card's body on every completed decode.
    private var thumbnails: [UUID: (key: ThumbnailCacheKey, image: CGImage)] = [:]

    private let asset: AVAsset
    /// Every scored frame of the source video (`DetectedClips.poseFrames`), handed to the
    /// editor so Auto follow can fit the crop around the keypoints in the trimmed window,
    /// including frames a trim pulled in from outside the clip's original window. Empty
    /// when nothing analyzed the video (the screenshot harness), in which case Auto crop
    /// has nothing to fit.
    private let poseFrames: [PoseFrameResult]
    /// The people whose tricks became clips, when the video was analyzed following everyone
    /// (`DetectedClips.people`); a clip with a `personID` reads its own person's frames instead
    /// of `poseFrames`.
    private let people: [PoseTrack]
    /// The source video's `PHAsset.localIdentifier`: the clip library's source and the
    /// contribution's video id.
    private let assetIdentifier: String
    private let loader: ClipThumbnailLoader
    /// One in-flight decode per id, tagged with the key it was started for — a caller
    /// only joins it when its own key still matches, so a request that arrives for a
    /// freshly-edited item never gets handed the pre-edit decode another caller is
    /// already waiting on.
    private var inFlight: [UUID: (key: ThumbnailCacheKey, task: Task<CGImage?, Never>)] = [:]
    private let exportClip: ExportOneClip
    private let saveToPhotos: SaveOneClipToPhotos
    private let recordSaved: RecordSavedClips
    /// The Photos asset each saved clip landed as, by item id: what the clip library records, and
    /// replaced when an edited clip is saved again.
    private var exportAssetIDs: [UUID: String] = [:]
    private let makeDirectory: @Sendable () -> URL
    /// Read once per `save()` run for the album destination — injected (like
    /// `CameraCaptureViewModel`'s own `settingsProvider`) so a test can drive the album-on
    /// path without touching the real `UserDefaults.standard`-backed singleton. `@MainActor`-typed
    /// so the default value's closure literal, which reads the main-actor-isolated
    /// `TurnipSettingsStore.shared`, type-checks as a default argument.
    private let settingsProvider: @MainActor () -> TurnipSettings
    private let autoFollow = AutoFollow()
    /// Auto follow's crop for each window a clip without a follow crop of its own has been drawn
    /// over, so its tile, poster and save fit it once.
    private var autoFollowCrops: [AutoFollowKey: FollowCrop] = [:]

    private struct AutoFollowKey: Hashable {
        let window: TrickWindow
        let cropRect: NormalizedRect
        let personID: Int?
    }
    private let announce: AccessibilityAnnouncing
    /// For a message that lands as the screen changes: the zero-tricks notice, shown as this
    /// screen is pushed, and the save's completion, posted just before the pop to Home.
    private let announceAfterScreenChange: AccessibilityAnnouncing

    /// The asset's duration in seconds, loaded once per asset and shared by every
    /// card's range timeline, its loop's window clamp, and `addClip()`. `nil` when the
    /// asset can't be read — the timeline then hides itself rather than guessing a scale.
    private var durationTask: Task<TimeInterval?, Never>?
    /// `assetDuration()`'s result once it has resolved: the same `AVAsset` duration the
    /// editor clamps a window to, which can differ from the Photos duration `items[0]` carries.
    private var loadedAssetDuration: TimeInterval?

    /// The video track and its geometry, loaded once per asset and shared by every
    /// card's live preview composition (`videoComposition(for:)`).
    private struct TrackGeometry {
        let track: AVAssetTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let frameRate: Float
        /// The track's exact frame spacing; `.invalid` when it can't be read, which
        /// the shared grid derivation treats as "fall back to the nominal rate".
        let minFrameDuration: CMTime
    }
    private var trackGeometryTask: Task<TrackGeometry?, Never>?

    /// Prepends the original-video item to `items`: the invariant that
    /// `items[0]` always stands for the source video, enforced in one place rather
    /// than left to every call site to remember. `duration` seeds its full-video
    /// window; the original never opens the editor, so this never needs re-deriving.
    ///
    /// `items` are the detected clips (`docs/UIUX.md` § "Clip Detail / Editor"): a clip with no
    /// follow crop of its own shows Auto follow's, or the whole frame held still when the video
    /// has no pose analysis to fit. A clip added later with "+" does the same.
    init(
        items: [ClipListItem],
        poseFrames: [PoseFrameResult] = [],
        people: [PoseTrack] = [],
        asset: AVAsset,
        assetIdentifier: String,
        duration: TimeInterval,
        loader: ClipThumbnailLoader = ClipThumbnailLoader(),
        exportClip: @escaping ExportOneClip = exportOneClip,
        saveToPhotos: @escaping SaveOneClipToPhotos = saveOneClipToPhotos,
        recordSaved: @escaping RecordSavedClips = { recordInClipLibrary($0) },
        makeDirectory: @escaping @Sendable () -> URL = defaultExportDirectory,
        settingsProvider: @escaping @MainActor () -> TurnipSettings = { TurnipSettingsStore.shared.current },
        announce: @escaping AccessibilityAnnouncing = postAccessibilityAnnouncement,
        announceAfterScreenChange: @escaping AccessibilityAnnouncing =
            postAccessibilityAnnouncementAfterScreenChange
    ) {
        let original = ClipListItem(
            window: TrickWindow(startTime: 0, endTime: max(duration, 0)),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            isOriginal: true)
        self.items = [original] + items
        self.poseFrames = poseFrames
        self.people = people
        self.asset = asset
        self.assetIdentifier = assetIdentifier
        self.loader = loader
        self.exportClip = exportClip
        self.saveToPhotos = saveToPhotos
        self.recordSaved = recordSaved
        self.makeDirectory = makeDirectory
        self.settingsProvider = settingsProvider
        self.announce = announce
        self.announceAfterScreenChange = announceAfterScreenChange
    }

    /// Where `item` sits among the detected clips, 1-based, and how many there are — the
    /// count a card's VoiceOver label reads off. `nil` for the original video, which stands
    /// for the source already in Photos rather than a detected clip.
    func clipPosition(of item: ClipListItem) -> (number: Int, count: Int)? {
        guard !item.isOriginal else { return nil }
        let clips = items.filter { !$0.isOriginal }
        guard let offset = clips.firstIndex(where: { $0.id == item.id }) else { return nil }
        return (offset + 1, clips.count)
    }

    /// How many clips a Save Clips tap would write to Photos — what the button announces before it
    /// is tapped, and what the save announces on its way in and out.
    var unsavedClipCount: Int {
        items.filter { !$0.isOriginal && !$0.isSaved }.count
    }

    /// Speaks the zero-tricks notice, which otherwise fades itself out unheard.
    func announceNoTricksFound() {
        announceAfterScreenChange(ClipListAccessibility.noTricksFound)
    }

    /// The analyzed asset, shared with the editor destination so it previews and
    /// exports from the same source the list's thumbnails were decoded from.
    var sourceAsset: AVAsset { asset }

    /// Builds the editor's input for one list item: its window, crop rect, and follow crop
    /// plus the analyzed asset and the video's scored frames. Never called for
    /// the original item, which never opens the editor.
    func editorSource(for item: ClipListItem) -> ClipEditorSource {
        ClipEditorSource(
            window: item.window,
            cropRect: item.cropRect,
            followCrop: item.followCrop,
            asset: asset,
            poseFrames: poseFrames(forPerson: item.personID))
    }

    /// The frames a clip's crop and follow path are fitted to: its own person's when it has one,
    /// every scored frame otherwise.
    private func poseFrames(forPerson personID: Int?) -> [PoseFrameResult] {
        personID.flatMap { id in people.first { $0.id == id }?.frames } ?? poseFrames
    }

    /// Applies the editor's commit to the item with the given id: the window, crop rect,
    /// and follow crop the user left the editor with replace the list entry's, so
    /// trim/crop edits commit on back-navigation (docs/UIUX.md § "Clip Detail / Editor").
    /// `isSaved` carries over only while the result still describes the video that landed:
    /// a clip the user retrimmed or recropped is not the one in Photos, so Save Clips has to
    /// export and save it again. Names carry over; the window stays detection's only while the
    /// editor left it as it was. A no-op for unknown ids.
    func applyEditorResult(_ result: ClipEditorResult, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        items[index] = ClipListItem(
            id: id,
            window: result.window,
            cropRect: result.cropRect,
            followCrop: result.followCrop,
            isSaved: item.isSaved && describesTheSameVideo(result, as: item),
            personID: item.personID,
            names: item.names,
            isMe: item.isMe,
            isAutoDetected: item.isAutoDetected && isSameWindow(result.window, as: item.window),
            proposal: item.proposal)
    }

    /// Whether `result` would export the same video as `item`. The editor commits on every
    /// close, so opening a clip only to watch it must not read as an edit. It also clamps a
    /// window that runs past the video's end when it loads, which changes the window without
    /// changing what an export of it contains. That clamp uses the asset's own duration, so the
    /// comparison does too; until the cards have loaded it, only an identical window matches.
    private func describesTheSameVideo(_ result: ClipEditorResult, as item: ClipListItem) -> Bool {
        isSameWindow(result.window, as: item.window)
            && result.cropRect == item.cropRect && result.followCrop == item.followCrop
    }

    /// Whether the editor's `window` is `previous` as it was, allowing for the clamp to the
    /// video's end the editor applies on load.
    private func isSameWindow(_ window: TrickWindow, as previous: TrickWindow) -> Bool {
        if window == previous { return true }
        guard let loadedAssetDuration else { return false }
        return window == ClipEditorViewModel.clamped(window: previous, to: loadedAssetDuration)
    }

    /// Removes the clip with the given id entirely, with no restore: Name Clips' "Remove this
    /// clip". The original item is never removed, since `items[0]` always stands for the
    /// source video. A no-op for unknown ids.
    func delete(_ id: UUID) {
        items.removeAll { $0.id == id && !$0.isOriginal }
        // The id is gone from `items` for good, so nothing will ever look these up
        // again — drop them rather than leaking one entry per deleted clip for the
        // life of the screen.
        thumbnails.removeValue(forKey: id)
        inFlight[id] = nil
    }

    /// The "+" button's action: appends a new clip covering the first few seconds of the
    /// asset (or its full duration if shorter), full-frame crop. The user trims it in the editor
    /// like any other clip; there's no separate creation UI.
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
        let duration = await durationTask.value
        loadedAssetDuration = duration
        return duration
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
                // `.invalid` keeps the preview available when only this read fails:
                // the grid derivation falls back to the nominal rate for it, exactly
                // as it does for a track that reports no usable spacing.
                let minFrameDuration = (try? await track.load(.minFrameDuration)) ?? .invalid
                return TrackGeometry(
                    track: track, naturalSize: naturalSize,
                    preferredTransform: preferredTransform, frameRate: frameRate,
                    minFrameDuration: minFrameDuration)
            }
        }
        guard let trackGeometryTask else { return nil }
        return await trackGeometryTask.value
    }

    /// The live preview composition for one tile's framing, applied to the full (untrimmed)
    /// source track — `AVPlayerLooper`'s own `timeRange` already bounds what actually loops,
    /// this only shapes the frame. Built from the same `ClipExportTransform.make` the exported
    /// clip and the card's poster thumbnail both use, so the live-playing tile, the poster
    /// underneath it, and the saved clip always agree on the framing. It renders the clip's
    /// moving crop, timed in source time since the player runs over the untrimmed asset.
    /// `nil` when the track geometry can't be loaded or the crop rect is degenerate — the
    /// caller falls back to an uncomposed player rather than showing nothing.
    ///
    /// Takes the tile's resolved geometry rather than a `ClipListItem`: the caller
    /// (`ClipCardPlayback`) already resolves its target geometry away from the (possibly
    /// stale-`self`) item, and threading a whole `ClipListItem` through here would tempt a
    /// caller into rereading `item` itself instead of passing the geometry it already resolved.
    func videoComposition(for geometry: ClipCardPlaybackGeometry) async -> AVVideoComposition? {
        guard let track = await trackGeometry(),
              let duration = try? await asset.load(.duration),
              let followCrop = await followCrop(
                  followCrop: geometry.followCrop, window: geometry.window, cropRect: geometry.cropRect,
                  personID: geometry.personID),
              // The composition's own grid (`makeVideoComposition` below), so every frame it
              // renders lands on a sample of the moving crop.
              let frameDuration = try? VideoFrameSampler.compositionFrameDuration(
                  minFrameDuration: track.minFrameDuration, nominalFrameRate: track.frameRate),
              let transform = ClipExportTransform.make(
                  followCrop: followCrop, cropRect: geometry.cropRect, over: 0...max(duration.seconds, 0),
                  frameDuration: frameDuration, naturalSize: track.naturalSize,
                  preferredTransform: track.preferredTransform)
        else { return nil }
        // A grid the shared derivation rejects (no usable timing value) drops the
        // composed preview the same way an unloadable track does — the caller
        // falls back to an uncomposed player rather than showing nothing.
        return try? transform.makeVideoComposition(
            for: track.track, duration: duration, frameRate: track.frameRate,
            minFrameDuration: track.minFrameDuration)
    }

    /// The follow crop a clip draws: its own, or — for a clip that has none yet — Auto follow's
    /// for its window (`AutoFollow.defaultCrop`), the same crop the editor opens it on. `nil` when
    /// the track geometry can't be loaded or the crop rect is degenerate.
    func followCrop(for item: ClipListItem) async -> FollowCrop? {
        await followCrop(
            followCrop: item.followCrop, window: item.window, cropRect: item.cropRect, personID: item.personID)
    }

    private func followCrop(
        followCrop: FollowCrop?, window: TrickWindow, cropRect: NormalizedRect, personID: Int?
    ) async -> FollowCrop? {
        if let followCrop { return followCrop }
        let key = AutoFollowKey(window: window, cropRect: cropRect, personID: personID)
        if let fitted = autoFollowCrops[key] { return fitted }
        guard let track = await trackGeometry() else { return nil }
        let geometry = VideoTrackGeometry(naturalSize: track.naturalSize, preferredTransform: track.preferredTransform)
        guard let crop = geometry.displayedCropRect(cropRect) else { return nil }
        let fitted = autoFollow.defaultCrop(
            poseFrames: poseFrames(forPerson: personID), window: window, cropRect: crop,
            videoSize: geometry.displayedSize)
        autoFollowCrops[key] = fitted
        return fitted
    }

    /// The card thumbnail, loading lazily. Idempotent and safe to call from every card's
    /// `.task`: repeat calls for an unchanged item return the cached image, and
    /// concurrent calls for the same item share one decode instead of seeking the same
    /// frame twice. The cache is keyed by the item's id *and* the fields the decoded
    /// frame depends on, so a call for the same id but a since-edited window/cropRect/
    /// followCrop always re-decodes — including when it races a still-in-flight
    /// decode for the pre-edit item, which it never joins. A cancelled caller never
    /// cancels the shared decode — the decode runs to completion and the result is
    /// cached, so a card that scrolls off-screen and back within the decode window gets
    /// its thumbnail from the re-fired `.task` instead of a discarded, already-paid-for
    /// decode. (Lingering decodes are intentional: `copyCGImage` is not cancellable, so
    /// cancelling the shared task cannot save the expensive work — it can only throw the
    /// result away from under another waiter.)
    func thumbnail(for item: ClipListItem) async -> CGImage? {
        let key = ThumbnailCacheKey(window: item.window, cropRect: item.cropRect, followCrop: item.followCrop)
        if let cached = thumbnails[item.id], cached.key == key {
            return cached.image
        }
        if let running = inFlight[item.id], running.key == key {
            return await running.task.value
        }
        let task = Task { [loader, asset, item] in
            let followCrop = await self.followCrop(for: item)
            return await loader.thumbnail(for: item, following: followCrop, in: asset)
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

    /// The "Save Clips" action: exports and saves every derived clip that has not already
    /// landed in Photos. Returns `true` when the screen should pop to Home; `false` when a clip failed, in which case
    /// `saveFailureMessage` is set and the screen stays up so Save Clips can be retried.
    ///
    /// Each clip is marked `isSaved` the moment its Photos write returns, and the loop
    /// skips the ones already marked. That is what makes the retry above safe: a clip
    /// that fails deterministically would otherwise cost the user one extra copy of
    /// every healthy clip per attempt, and a Photos asset the app wrote is not
    /// something the app can take back.
    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        let directory = makeDirectory()
        sweepStaleExportDirectories(in: directory.deletingLastPathComponent(), excluding: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Read once for the whole run rather than per clip: every clip in one Save Clips tap saves to
        // the same destination, and a setting change mid-save shouldn't split a run across two
        // albums.
        let albumTitle = settingsProvider().albumDestination
        let clipCount = unsavedClipCount
        // A run with no clip to write has no work to announce.
        if clipCount > 0 {
            announce(ClipListAccessibility.saveStarting(clipCount: clipCount))
        }
        var failures: [String] = []
        for item in items where !item.isOriginal && !item.isSaved {
            do {
                let spec = ClipSpec(
                    window: item.window, cropRect: item.cropRect, followCrop: await followCrop(for: item))
                let fileURL = try await exportClip(spec, asset, directory) { _ in }
                exportAssetIDs[item.id] = try await saveToPhotos(fileURL, albumTitle)
                markSaved(item.id)
            } catch {
                // Numbered by card, not by run: a retry skips the clips already saved, and
                // the number has to lead a listener back to the card that failed.
                let position = clipPosition(of: item)
                failures.append(ClipListAccessibility.saveFailure(
                    clipNumber: position?.number ?? 0, clipCount: position?.count ?? 0,
                    reason: Self.reason(for: error)))
            }
        }
        // A partial failure records what did land, so a clip in Photos is never missing from the
        // Profile.
        let earned = recordLibrary()
        guard failures.isEmpty else {
            saveFailureMessage = failures.joined(separator: "\n")
            return false
        }

        if clipCount > 0 {
            var message = ClipListAccessibility.saveFinished(clipCount: clipCount)
            if !earned.isEmpty {
                message += ". " + ProfileAccessibility.earnedAnnouncement(earned)
            }
            announceAfterScreenChange(message)
        }
        return true
    }

    /// Writes every clip in Photos into the clip library with the names it has now: a name given
    /// between a partial failure and the retry reaches the library too.
    private func recordLibrary() -> [EarnedAchievement] {
        let saved = items.compactMap { item -> LibrarySave.Clip? in
            guard !item.isOriginal, item.isSaved, let exportAssetID = exportAssetIDs[item.id] else { return nil }
            return LibrarySave.Clip(
                id: item.id, window: item.window, exportAssetID: exportAssetID, names: item.names,
                isMe: item.isMe, isAutoDetected: item.isAutoDetected, proposal: item.proposal)
        }
        guard !saved.isEmpty else { return [] }
        return recordSaved(LibrarySave(
            sourceAssetID: assetIdentifier, sourceDuration: loadedAssetDuration ?? items[0].window.endTime,
            clips: saved))
    }

    /// Records that one clip's video is now in Photos. Resolved by id rather than
    /// written through the loop's own value copy of the item, which no longer refers to
    /// anything stored once it has been read out of `items`.
    private func markSaved(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSaved = true
    }

    /// The failure message for one clip. Adapters throw `ClipSaveError` to get the
    /// failed step named; anything else falls back to its localized description.
    private static func reason(for error: Error) -> String {
        switch error {
        case ClipSaveError.exportFailed(let reason):
            return String(localized: "Export failed — \(reason)")
        case ClipSaveError.photosSaveFailed(let reason):
            return String(localized: "Couldn't save to Photos — \(reason)")
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Naming

/// What Name Clips writes (`docs/UIUX.md` § "Name Clips", `docs/PROFILE_DESIGN.md` §4): names on
/// the items themselves, so an editor commit or a page change keeps every name given so far.
extension ClipListViewModel {
    /// The clips Name Clips pages through: every derived clip, in order.
    var clipsToName: [ClipListItem] { items.filter { !$0.isOriginal } }

    /// Whether the video has pose analysis to contribute. A video reached by "Clip manually" has
    /// none, so its clips can be named but are never contributed.
    var hasPose: Bool { !poseFrames.isEmpty }

    /// The names already given on this video, each once, in the order first given — the first
    /// suggestions, since a session is mostly repeats of a few tricks.
    var namesUsedOnVideo: [String] {
        var seen = Set<String>()
        return clipsToName.flatMap(\.names).map(\.name).filter { seen.insert(TrickVocabulary.normalized($0)).inserted }
    }

    /// Adds a trick name to a clip, trimmed; a blank name, or one the clip already has in any
    /// case, changes nothing.
    func addName(_ name: String, origin: LabelOrigin, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var names = items[index].names
        guard names.addName(name, origin: origin) else { return }
        items[index].names = names
    }

    /// Removes a name.
    func removeName(_ name: ClipName, from id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].names.removeAll { $0 == name }
    }

    /// "Did you mean": puts the vocabulary's spelling in the typed name's place, as a pick.
    func replaceName(_ name: ClipName, with canonical: String, in id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var names = items[index].names
        guard names.replaceName(name, with: canonical) else { return }
        items[index].names = names
    }

    /// Who is in a clip. A change on a person's first clip carries to that person's later clips
    /// that still read the way the first one did, so one choice covers a take while any clip set
    /// apart keeps its own.
    func setIsMe(_ isMe: Bool, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        let samePerson = clipsToName.filter { $0.personID == item.personID }
        if samePerson.first?.id == id {
            for other in samePerson.dropFirst() where other.isMe == item.isMe {
                if let otherIndex = items.firstIndex(where: { $0.id == other.id }) { items[otherIndex].isMe = isMe }
            }
        }
        items[index].isMe = isMe
    }

    /// The contribution the saved, named clips make, laid out for the confirmation sheet — none
    /// while Settings' Contribute named clips is off, or for a video with no pose analysis.
    func contributionPlan() -> ContributionPlan {
        let contributes = settingsProvider().contributesClips && hasPose
        return ContributionPlan(
            clips: contributes ? items.filter { !$0.isOriginal && $0.isSaved && !$0.names.isEmpty } : [],
            videoID: VideoIdentity.videoID(forAssetIdentifier: assetIdentifier),
            duration: loadedAssetDuration ?? items.first?.window.endTime ?? 0,
            poseFrames: poseFrames(forPerson:))
    }
}
