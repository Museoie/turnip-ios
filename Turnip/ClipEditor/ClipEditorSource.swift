import AVFoundation
import CoreGraphics
import Foundation

/// A user-applied adjustment on top of the algorithmic crop rect: the pinch/rotate/drag
/// gesture in the editor's crop preview (`docs/UIUX.md` § "Clip Detail / Editor").
/// `scale`/`rotationRadians`/`offset` transform the *video* while the crop rect's marker
/// stays fixed on screen — equivalent to moving the crop rect the opposite way in the
/// source's frame. Identity reproduces the algorithm's own framing exactly.
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
/// outward pulls new frames into the window, and Auto crop fits whichever frames the
/// trimmed window holds.
///
/// `framingMode` and `followCrop` are the clip's as `ClipListItem` carries them: a clip in
/// Follow with no follow crop yet opens on Auto follow's.
struct ClipEditorSource {
    let window: TrickWindow
    let cropRect: NormalizedRect
    let cropAdjustment: CropAdjustment
    let framingMode: FramingMode
    let followCrop: FollowCrop?
    let asset: AVAsset
    let poseFrames: [PoseFrameResult]

    init(
        window: TrickWindow,
        cropRect: NormalizedRect,
        cropAdjustment: CropAdjustment = .identity,
        framingMode: FramingMode = .still,
        followCrop: FollowCrop? = nil,
        asset: AVAsset,
        poseFrames: [PoseFrameResult]
    ) {
        self.window = window
        self.cropRect = cropRect
        self.cropAdjustment = cropAdjustment
        self.framingMode = framingMode
        self.followCrop = followCrop
        self.asset = asset
        self.poseFrames = poseFrames
    }
}

/// The editor's edits, committed on back-navigation: the design doc wants no separate save
/// step, so the view hands `result` to its commit closure when the editor disappears, and
/// the clip list applies it to its item.
///
/// It carries both modes' framings, whichever is active, and the clip keeps both. A
/// `followCrop` the editor only ever showed as Auto follow's for the window it opened with
/// comes back `nil`, as it went in.
struct ClipEditorResult: Equatable, Sendable {
    let window: TrickWindow
    let cropRect: NormalizedRect
    let cropAdjustment: CropAdjustment
    var framingMode: FramingMode = .follow
    var followCrop: FollowCrop?
}
