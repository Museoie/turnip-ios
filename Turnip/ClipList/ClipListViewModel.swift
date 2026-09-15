import AVFoundation
import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// Backing store for `ClipListView` (`docs/UIUX.md` § "Clip List (triage)").
@MainActor
final class ClipListViewModel: ObservableObject {
    @Published private(set) var items: [ClipListItem]

    /// Decoded thumbnails by item id. Plain storage, not `@Published`: no view reads
    /// this dictionary — each card renders from its own `@State` thumbnail — so
    /// publishing it would re-evaluate every card's body on every completed decode.
    private var thumbnails: [UUID: CGImage] = [:]

    private let asset: AVAsset
    private let loader: ClipThumbnailLoader
    private var inFlight: [UUID: Task<CGImage?, Never>] = [:]

    /// The video track's geometry, loaded once per asset and shared by every card's
    /// placeholder-ratio math. `nil` when the asset has no video track or can't be
    /// read — cards then fall back to the crop rect's own (encoded-space) ratio.
    private var trackGeometryTask: Task<
        (naturalSize: CGSize, preferredTransform: CGAffineTransform)?, Never
    >?

    /// The asset's duration in seconds, loaded once per asset and shared by every
    /// card's inline trim timeline. `nil` when the asset can't be read — the timeline
    /// then hides itself rather than guessing a scale.
    private var durationTask: Task<TimeInterval?, Never>?

    init(
        items: [ClipListItem],
        asset: AVAsset,
        loader: ClipThumbnailLoader = ClipThumbnailLoader()
    ) {
        self.items = items
        self.asset = asset
        self.loader = loader
    }

    /// The export action's input. Non-empty by default since every item starts kept
    /// (see `ClipListItem`).
    var keptItems: [ClipListItem] {
        items.filter(\.isKept)
    }

    /// "Export N clips", disabled until at least one clip is kept.
    var exportTitle: String {
        let count = keptItems.count
        return "Export \(count) clip\(count == 1 ? "" : "s")"
    }

    var canExport: Bool {
        !keptItems.isEmpty
    }

    /// The analyzed asset, shared with the editor and export-confirmation
    /// destinations so they preview and export from the same source the list's
    /// thumbnails were decoded from.
    var sourceAsset: AVAsset { asset }

    /// The export action's input as the confirmation screen takes it: one entry
    /// per kept clip, carrying the id, window, and crop rect it exports with.
    var exportConfirmationItems: [ExportConfirmationItem] {
        keptItems.map {
            ExportConfirmationItem(id: $0.id, window: $0.window, cropRect: $0.cropRect)
        }
    }

    /// Builds the editor's input for one list item: its window, crop rect, and
    /// keep/discard state plus the analyzed asset.
    ///
    /// `poseFrames` is empty — the pipeline's sampled frames don't reach the
    /// list yet (the Home → Processing wiring threads them through when it
    /// lands), so the editor keeps the pipeline-computed crop rect instead of
    /// re-deriving it when a trim handle drags outward past the original
    /// window. Trimming, the live crop preview, and keep/discard all work;
    /// only the re-derivation for newly included frames waits on the frames.
    func editorSource(for item: ClipListItem) -> ClipEditorSource {
        ClipEditorSource(
            window: item.window,
            cropRect: item.cropRect,
            isKept: item.isKept,
            asset: asset,
            poseFrames: [])
    }

    /// Applies the editor's commit to the item with the given id: the window,
    /// crop rect, and keep/discard decision the user left the editor with
    /// replace the list entry's, so trim/crop edits commit on back-navigation
    /// (docs/UIUX.md § "Clip Detail / Editor"). A no-op for unknown ids — the
    /// item may have been removed by a re-run of detection while the editor
    /// was open.
    func applyEditorResult(_ result: ClipEditorResult, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = ClipListItem(
            id: id,
            window: result.window,
            cropRect: result.cropRect,
            isKept: result.isKept)
    }

    /// The per-card keep/discard quick action. A no-op for unknown ids — the card that
    /// fired it may have been removed by a re-run of detection.
    func toggleKeep(_ item: ClipListItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isKept.toggle()
    }

    /// True when every clip is kept (and there is at least one). Drives the toolbar's
    /// "Select All" / "Deselect All" label.
    var allKept: Bool {
        !items.isEmpty && items.allSatisfy(\.isKept)
    }

    /// Marks every clip kept — the toolbar's "Select All" action.
    func selectAll() {
        for index in items.indices {
            items[index].isKept = true
        }
    }

    /// Clears every clip's keep flag — the toolbar's "Deselect All" action, shown when
    /// everything is already kept.
    func deselectAll() {
        for index in items.indices {
            items[index].isKept = false
        }
    }

    /// Replaces the window of the item with the given id — the card's inline trim
    /// timeline writes through this. The crop rect and keep/discard decision are
    /// preserved; only the window moves. A no-op for unknown ids, same convention as
    /// `toggleKeep`.
    func setWindow(_ window: TrickWindow, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let current = items[index]
        items[index] = ClipListItem(
            id: id,
            window: window,
            cropRect: current.cropRect,
            isKept: current.isKept)
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

    /// The placeholder tile's aspect ratio for `item`, computed in the displayed
    /// frame's space — the space the decoded thumbnail renders in — so cards don't
    /// reflow when thumbnails land. Falls back to the crop rect's own ratio
    /// (encoded space, the previous behavior) when the track geometry can't be
    /// loaded, and to 9:16 for a degenerate crop rect.
    func placeholderAspectRatio(for item: ClipListItem) async -> CGFloat {
        if let (naturalSize, preferredTransform) = await trackGeometry() {
            return ClipThumbnailLoader.displayedAspectRatio(
                cropRect: item.cropRect,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform)
        }
        let width = CGFloat(item.cropRect.width), height = CGFloat(item.cropRect.height)
        guard width > 0, height > 0 else { return 9.0 / 16.0 }
        return width / height
    }

    /// Loads the video track's geometry once per asset; concurrent callers share the
    /// single in-flight task. `@MainActor`-serialized, so the check-then-set is
    /// race-free (same pattern as `inFlight` above).
    private func trackGeometry() async -> (
        naturalSize: CGSize, preferredTransform: CGAffineTransform
    )? {
        if trackGeometryTask == nil {
            trackGeometryTask = Task { [asset] in
                guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                      let naturalSize = try? await track.load(.naturalSize),
                      let preferredTransform = try? await track.load(.preferredTransform)
                else { return nil }
                return (naturalSize, preferredTransform)
            }
        }
        guard let task = trackGeometryTask else { return nil }
        return await task.value
    }

    /// Loads the asset's duration once per asset; concurrent callers share the single
    /// in-flight task. `@MainActor`-serialized, so the check-then-set is race-free
    /// (same pattern as `trackGeometry` above).
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

    /// The card thumbnail, loading lazily. Idempotent and safe to call from every card's
    /// `.task`: repeat calls return the cached image, and concurrent calls for the same
    /// card share one decode instead of seeking the same frame twice. A cancelled caller
    /// never cancels the shared decode — the decode runs to completion and the result is
    /// cached, so a card that scrolls off-screen and back within the decode window gets
    /// its thumbnail from the re-fired `.task` instead of a discarded, already-paid-for
    /// decode. (Lingering decodes are intentional: `copyCGImage` is not cancellable, so
    /// cancelling the shared task cannot save the expensive work — it can only throw the
    /// result away from under another waiter.)
    func thumbnail(for item: ClipListItem) async -> CGImage? {
        if let cached = thumbnails[item.id] {
            return cached
        }
        if let running = inFlight[item.id] {
            return await running.value
        }
        let task = Task { [loader, asset, item] in
            await loader.thumbnail(for: item, in: asset)
        }
        inFlight[item.id] = task
        let image = await task.value
        inFlight[item.id] = nil
        if let image = image {
            thumbnails[item.id] = image
        }
        return image
    }
}
