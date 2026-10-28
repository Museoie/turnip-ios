import Foundation

/// One triage card's data: a detected trick window plus its computed crop rect
/// (docs/DESIGN.md pipeline steps 5-6), with the user's trash decision.
///
/// `isTrashed` defaults to `false`: every clip starts untrashed. It's the original
/// item's own reversible flag — `ClipListViewModel.save()` reads it to decide
/// whether to delete the source video from Photos — while Name Clips' "Remove this
/// clip" removes a derived clip outright (`ClipListViewModel.delete(_:)`) instead of
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
/// `framingMode` is which of the editor's framings the clip shows: `cropAdjustment` is Still's,
/// `followCrop` Follow's. `ClipListViewModel` puts every clip it holds in Follow (`docs/UIUX.md`
/// § "Clip Detail / Editor"). A clip in Follow whose `followCrop` is still `nil` shows Auto
/// follow's crop for its window, worked out where it is drawn
/// (`ClipListViewModel.followCrop(for:)`).
///
/// `names` and `isMe` are what Name Clips gives a clip (`docs/UIUX.md` § "Name Clips"): its
/// trick names with how each was given, and whether it shows the user. Whether its names go to
/// the farm once saved is Settings' Contribute named clips, for every clip at once.
/// `isAutoDetected` says the window is still the one detection proposed — the farm's
/// `auto_detected` — and goes off for a clip added by hand or retrimmed in the editor.
///
/// `isOriginal` marks the one item — always `ClipListViewModel.items[0]` — that
/// stands for the source video already in Photos rather than a derived clip: it
/// carries the full-video window and full-frame crop, is never opened in the
/// editor, and its trash is the reversible `isTrashed` flag above rather than an
/// outright removal.
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
    /// Whose trick this is, when the video was analyzed following everyone
    /// (`DetectedClips.people`): its crop, follow path and the editor's Auto crop read only that
    /// person's pose. `nil` for the original, a clip added by hand, and every clip of a video
    /// analyzed following one person, which read every scored frame.
    let personID: Int?
    var names: [ClipName]
    var isMe: Bool
    let isAutoDetected: Bool

    init(
        id: UUID = UUID(),
        window: TrickWindow,
        cropRect: NormalizedRect,
        cropAdjustment: CropAdjustment = .identity,
        framingMode: FramingMode = .follow,
        followCrop: FollowCrop? = nil,
        isTrashed: Bool = false,
        isSaved: Bool = false,
        isOriginal: Bool = false,
        personID: Int? = nil,
        names: [ClipName] = [],
        isMe: Bool = true,
        isAutoDetected: Bool = false
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
        self.personID = personID
        self.names = names
        self.isMe = isMe
        self.isAutoDetected = isAutoDetected
    }

    /// "2.4s"-style duration label for the card, via the one shared clip-duration
    /// formatter — the triage card and the editor must render the same window
    /// identically.
    var durationLabel: String {
        ClipDurationFormatter.string(from: window.endTime - window.startTime)
    }
}
