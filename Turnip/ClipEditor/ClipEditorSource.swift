import AVFoundation
import CoreGraphics
import Foundation

/// The video turned, zoomed and moved about the clip's crop rect's center while the crop rect's
/// marker stays fixed on screen — equivalent to moving the crop rect the opposite way in the
/// source's frame. What `ClipExportTransform` renders one moment of a follow crop through, and the
/// terms Auto follow's one-keyframe fit is worked out in
/// (`ClipEditorViewModel.autoCropAdjustment`). Identity reproduces the crop rect's own framing.
///
/// Plain `Double`/`CGFloat` fields rather than SwiftUI's `Angle`: this type flows into
/// `ClipExportTransform`, which has no SwiftUI dependency.
struct CropAdjustment: Hashable, Sendable {
    var scale: CGFloat
    var rotationRadians: Double
    var offset: CGSize

    static let identity = CropAdjustment(scale: 1, rotationRadians: 0, offset: .zero)
}

/// What the clip editor opens with (`docs/UIUX.md` § "Clip Detail / Editor").
///
/// `poseFrames` carries *every* sampled frame, not just the window's: dragging a handle
/// outward pulls new frames into the window, and Auto follow fits whichever frames the
/// trimmed window holds.
///
/// `followCrop` is the clip's as `ClipListItem` carries it: a clip with no follow crop yet opens
/// on Auto follow's.
struct ClipEditorSource {
    let window: TrickWindow
    let cropRect: NormalizedRect
    let followCrop: FollowCrop?
    let asset: AVAsset
    let poseFrames: [PoseFrameResult]

    init(
        window: TrickWindow,
        cropRect: NormalizedRect,
        followCrop: FollowCrop? = nil,
        asset: AVAsset,
        poseFrames: [PoseFrameResult]
    ) {
        self.window = window
        self.cropRect = cropRect
        self.followCrop = followCrop
        self.asset = asset
        self.poseFrames = poseFrames
    }
}

/// The editor's edits, committed on back-navigation: the design doc wants no separate save
/// step, so the view hands `result` to its commit closure when the editor disappears, and
/// the clip list applies it to its item.
///
/// A `followCrop` the editor only ever showed as Auto follow's for the window it opened with
/// comes back `nil`, as it went in.
struct ClipEditorResult: Equatable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
    var followCrop: FollowCrop?
}
