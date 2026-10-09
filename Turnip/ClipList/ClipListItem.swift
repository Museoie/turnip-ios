import Foundation

/// One triage card's data: a detected trick window plus its computed crop rect
/// (docs/DESIGN.md pipeline steps 5-6), with the user's trash decision.
///
/// `isTrashed` defaults to `false`: every clip starts untrashed. It's the original
/// tile's own reversible flag — `ClipListViewModel.save()` reads it to decide
/// whether to delete the source video from Photos — while a derived clip's trash
/// button removes the item outright (`ClipListViewModel.delete(_:)`) instead of
/// setting this, so it never goes `true` on one in practice. `Identifiable` by a
/// stable `id` (not the window times) so view state survives an edit that changes
/// the window.
///
/// `isOriginal` marks the one item — always `ClipListViewModel.items[0]` — that
/// stands for the source video already in Photos rather than a derived clip: it
/// carries the full-video window and full-frame crop, is never opened in the
/// editor, and its trash button is the reversible `isTrashed` toggle above rather
/// than an outright removal.
struct ClipListItem: Hashable, Identifiable, Sendable {
    let id: UUID
    let window: TrickWindow
    let cropRect: NormalizedRect
    /// The editor's manual pinch/rotate/drag adjustment on top of `cropRect`, carried so
    /// it survives a re-open of the editor and reaches export.
    var cropAdjustment: CropAdjustment
    var isTrashed: Bool
    let isOriginal: Bool

    init(
        id: UUID = UUID(),
        window: TrickWindow,
        cropRect: NormalizedRect,
        cropAdjustment: CropAdjustment = .identity,
        isTrashed: Bool = false,
        isOriginal: Bool = false
    ) {
        self.id = id
        self.window = window
        self.cropRect = cropRect
        self.cropAdjustment = cropAdjustment
        self.isTrashed = isTrashed
        self.isOriginal = isOriginal
    }

    /// "2.4s"-style duration label for the card, via the one shared clip-duration
    /// formatter — the triage card and the editor must render the same window
    /// identically.
    var durationLabel: String {
        ClipDurationFormatter.string(from: window.endTime - window.startTime)
    }
}
