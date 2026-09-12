import AVFoundation
import Foundation

/// What the clip editor opens with (`docs/UIUX.md` § "Clip Detail / Editor").
///
/// `poseFrames` carries *every* sampled frame, not just the window's: dragging a handle
/// outward pulls new frames into play, and the crop rect is re-derived from whichever
/// frames are in play.
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
