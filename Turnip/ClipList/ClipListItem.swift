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
/// `isSaved` records that this clip's video has already been written to Photos by
/// `ClipListViewModel.save()`. It exists so that a Save Clips retried after a partial
/// failure re-exports only the clips still missing from the library: without it the
/// save loop's predicate matches every clip again and the ones that already landed
/// get written a second time, which nothing in the app can undo. It resets when the
/// editor commits different geometry (`ClipListViewModel.applyEditorResult(_:to:)`),
/// since an edited clip is no longer the one that was saved; opening a clip and closing
/// it unchanged leaves it set.
///
/// `framingMode` is which of the editor's two framings the clip shows (`docs/UIUX.md` § "Two
/// framing modes, Still and Follow"): `cropAdjustment` is Still's, `followCrop` Follow's. The
/// clip keeps both, so the editor's switch can go back to either. A clip in Follow whose
/// `followCrop` is still `nil` shows Auto follow's crop for its window, worked out where it is
/// drawn (`ClipListViewModel.followCrop(for:)`): a detected clip starts that way when Settings'
/// Follow the athlete is on.
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
    var framingMode: FramingMode
    var followCrop: FollowCrop?
    var isTrashed: Bool
    var isSaved: Bool
    let isOriginal: Bool

    init(
        id: UUID = UUID(),
        window: TrickWindow,
        cropRect: NormalizedRect,
        cropAdjustment: CropAdjustment = .identity,
        framingMode: FramingMode = .still,
        followCrop: FollowCrop? = nil,
        isTrashed: Bool = false,
        isSaved: Bool = false,
        isOriginal: Bool = false
    ) {
        self.id = id
        self.window = window
        self.cropRect = cropRect
        self.cropAdjustment = cropAdjustment
        self.framingMode = framingMode
        self.followCrop = followCrop
        self.isTrashed = isTrashed
        self.isSaved = isSaved
        self.isOriginal = isOriginal
    }

    /// "2.4s"-style duration label for the card, via the one shared clip-duration
    /// formatter — the triage card and the editor must render the same window
    /// identically.
    var durationLabel: String {
        ClipDurationFormatter.string(from: window.endTime - window.startTime)
    }
}
