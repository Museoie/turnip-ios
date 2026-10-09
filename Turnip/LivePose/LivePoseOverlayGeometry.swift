import CoreGraphics
import Foundation

/// The skeleton to draw for one pose, as points already mapped into the drawing surface's
/// coordinates: a dot per confident joint and a line per limb whose two joints are both
/// confident. Pure so the filtering and pairing can be tested without a preview layer; the
/// caller supplies the coordinate mapping (on the camera, the preview layer's own
/// device-point conversion, which accounts for orientation, mirroring and aspect-fill).
struct LivePoseOverlayGeometry: Equatable {
    struct Limb: Equatable {
        let start: CGPoint
        let end: CGPoint
    }

    let joints: [CGPoint]
    let limbs: [Limb]

    /// Joints at or below `PoseKeypoint.confidenceThreshold` are left out entirely rather than
    /// drawn hollow as `PoseOverlayView` does: on a live preview a guess drawn over the athlete
    /// reads as a wrong detection, not as a guess.
    init(keypoints: [PoseKeypoint], convert: (PoseKeypoint) -> CGPoint) {
        let usable = keypoints.filter { $0.confidence > PoseKeypoint.confidenceThreshold }
        let byName = Dictionary(usable.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        joints = usable.map(convert)
        limbs = PoseOverlayView.edges.compactMap { edge in
            guard let first = byName[edge.0], let second = byName[edge.1] else { return nil }
            return Limb(start: convert(first), end: convert(second))
        }
    }
}
