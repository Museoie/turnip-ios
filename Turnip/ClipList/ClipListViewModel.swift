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

    /// The per-card keep/discard quick action. A no-op for unknown ids — the card that
    /// fired it may have been removed by a re-run of detection.
    func toggleKeep(_ item: ClipListItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isKept.toggle()
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
