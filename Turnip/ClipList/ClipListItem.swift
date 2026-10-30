import Foundation

/// One clip's data: a detected trick window plus its computed crop rect (docs/DESIGN.md
/// pipeline steps 5-6). `Identifiable` by a stable `id` (not the window times) so view state
/// survives an edit that changes the window.
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
/// `followCrop` is the clip's framing, the crop moving with the athlete (`docs/UIUX.md`
/// § "Clip Detail / Editor"). A clip whose `followCrop` is still `nil` shows Auto follow's crop
/// for its window, worked out where it is drawn (`ClipListViewModel.followCrop(for:)`).
///
/// `names` and `isMe` are what Name Clips gives a clip (`docs/UIUX.md` § "Name Clips"): its
/// trick names with how each was given, and whether it shows the user. Whether its names go to
/// the farm once saved is Settings' Contribute named clips, for every clip at once.
/// `isAutoDetected` says the window is still the one detection proposed — the farm's
/// `auto_detected` — and goes off for a clip added by hand or retrimmed in the editor.
/// `proposal` is how the trick model proposed the clip, `nil` when it didn't; it stays with the
/// clip through every edit, since it records what the model offered, not what the clip is now.
///
/// `isOriginal` marks the one item — always `ClipListViewModel.items[0]` — that
/// stands for the source video already in Photos rather than a derived clip: it
/// carries the full-video window and full-frame crop, and is never paged through,
/// opened in the editor, saved or removed.
struct ClipListItem: Hashable, Identifiable, Sendable {
    let id: UUID
    let window: TrickWindow
    let cropRect: NormalizedRect
    var followCrop: FollowCrop?
    var isSaved: Bool
    let isOriginal: Bool
    /// Whose trick this is, when the video was analyzed following everyone
    /// (`DetectedClips.people`): its crop, follow path and the editor's Auto follow read only that
    /// person's pose. `nil` for the original, a clip added by hand, and every clip of a video
    /// analyzed following one person, which read every scored frame.
    let personID: Int?
    var names: [ClipName]
    var isMe: Bool
    let isAutoDetected: Bool
    let proposal: ModelProposal?

    init(
        id: UUID = UUID(),
        window: TrickWindow,
        cropRect: NormalizedRect,
        followCrop: FollowCrop? = nil,
        isSaved: Bool = false,
        isOriginal: Bool = false,
        personID: Int? = nil,
        names: [ClipName] = [],
        isMe: Bool = true,
        isAutoDetected: Bool = false,
        proposal: ModelProposal? = nil
    ) {
        self.id = id
        self.window = window
        self.cropRect = cropRect
        self.followCrop = followCrop
        self.isSaved = isSaved
        self.isOriginal = isOriginal
        self.personID = personID
        self.names = names
        self.isMe = isMe
        self.isAutoDetected = isAutoDetected
        self.proposal = proposal
    }

    /// "2.4s"-style duration label for the card, via the one shared clip-duration
    /// formatter — the triage card and the editor must render the same window
    /// identically.
    var durationLabel: String {
        ClipDurationFormatter.string(from: window.endTime - window.startTime)
    }
}
