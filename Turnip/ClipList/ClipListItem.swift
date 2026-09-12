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

    /// "2.4s"-style duration label for the card. Integer math pins exactly one decimal
    /// place: string-interpolating the `Double` would lean on `Double.description`'s
    /// shortest-round-trip rendering for the trailing `.0`, and the decimal separator
    /// must never follow the device locale (a German-locale "2,4s" would read as a list
    /// separator next to the clip count).
    var durationLabel: String {
        let tenths = Int(((window.endTime - window.startTime) * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)s"
    }
}
