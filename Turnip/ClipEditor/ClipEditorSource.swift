import AVFoundation
import Foundation

/// What the clip editor opens with (`docs/UIUX.md` § "Clip Detail / Editor", issue #18).
///
/// Every type here lives on main, so this screen compiles without the clip list (#11) or
/// the processing screen (#17): the list maps its item onto this source — window, crop
/// rect, keep state — and passes the pipeline's sampled pose frames through, when it wires
/// this destination in.
///
/// `poseFrames` carries *every* sampled frame, not just the window's: dragging a handle
/// outward pulls new frames into play, and #18 requires the crop rect to be re-derived
/// from whichever frames are in play (#9's algorithm).
struct ClipEditorSource {
    let window: TrickWindow
    let cropRect: NormalizedRect
    let isKept: Bool
    let asset: AVAsset
    let poseFrames: [PoseFrameResult]
}

/// The editor's edits, committed on back-navigation: the design doc wants no separate save
/// step, so the view hands `result` to its commit closure when the editor disappears, and
/// the clip list applies it to its item.
struct ClipEditorResult: Equatable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
    let isKept: Bool
}
