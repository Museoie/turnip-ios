import Foundation

/// One triage card's data: a detected trick window plus its computed crop rect
/// (docs/DESIGN.md pipeline steps 5-6), with the user's keep/discard decision.
///
/// `isKept` defaults to `true`: the resolved bulk keep/discard decision in
/// `docs/UIUX.md` says every clip starts kept and discarding is per-card, so the list
/// shows everything until the user opts a clip out. `Identifiable` by a stable `id`
/// (not the window times) so view state survives a re-run of detection producing
/// slightly different windows.
struct ClipListItem: Hashable, Identifiable, Sendable {
    let id: UUID
    let window: TrickWindow
    let cropRect: NormalizedRect
    var isKept: Bool

    init(
        id: UUID = UUID(),
        window: TrickWindow,
        cropRect: NormalizedRect,
        isKept: Bool = true
    ) {
        self.id = id
        self.window = window
        self.cropRect = cropRect
        self.isKept = isKept
    }

    /// "2.4s"-style duration label for the card, via the one shared clip-duration
    /// formatter — the triage card, the editor, and the export confirmation row must
    /// render the same window identically.
    var durationLabel: String {
        ClipDurationFormatter.string(from: window.endTime - window.startTime)
    }
}
