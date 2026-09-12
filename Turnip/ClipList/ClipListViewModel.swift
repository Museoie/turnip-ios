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
    /// Keyed by id on both ends rather than closing over an index, so a re-run of
    /// detection reordering the list can't make the binding write to a different clip.
    /// `nil` when the id is no longer in the list.
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

    /// The card thumbnail, loading lazily. Idempotent and safe to call from every card's
    /// `.task`: repeat calls return the cached image, and concurrent calls for the same
    /// card share one decode instead of seeking the same frame twice.
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
