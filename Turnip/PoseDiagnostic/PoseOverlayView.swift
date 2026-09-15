import SwiftUI

/// One frame's 17 keypoints drawn over the video, so a row's numbers can be checked against
/// what the frame actually shows. Joints above `PoseKeypoint.confidenceThreshold` draw filled,
/// with the COCO skeleton between them; the rest draw hollow, so a low-confidence guess is
/// visible as a guess rather than hidden.
///
/// Keypoints are frame-normalized in display orientation (the sampler's render space), so the
/// canvas must have the displayed video's aspect ratio for a plain multiply to land on the
/// right pixel — `PoseDiagnosticView` sizes the player stack to `displaySize` for exactly that.
struct PoseOverlayView: View {
    let keypoints: [PoseKeypoint]

    /// COCO-17 limb pairs, by `PoseKeypoint.names`.
    static let edges: [(String, String)] = [
        ("left_shoulder", "right_shoulder"), ("left_hip", "right_hip"),
        ("left_shoulder", "left_hip"), ("right_shoulder", "right_hip"),
        ("left_shoulder", "left_elbow"), ("left_elbow", "left_wrist"),
        ("right_shoulder", "right_elbow"), ("right_elbow", "right_wrist"),
        ("left_hip", "left_knee"), ("left_knee", "left_ankle"),
        ("right_hip", "right_knee"), ("right_knee", "right_ankle"),
        ("nose", "left_eye"), ("nose", "right_eye"),
        ("left_eye", "left_ear"), ("right_eye", "right_ear")
    ]

    private static let jointRadius: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let byName = Dictionary(keypoints.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            for edge in Self.edges {
                guard let first = byName[edge.0], let second = byName[edge.1],
                      first.isUsable, second.isUsable
                else { continue }
                var limb = Path()
                limb.move(to: Self.point(for: first, in: size))
                limb.addLine(to: Self.point(for: second, in: size))
                context.stroke(limb, with: .color(.green), lineWidth: 2)
            }
            for keypoint in keypoints {
                let center = Self.point(for: keypoint, in: size)
                let joint = Path(ellipseIn: CGRect(
                    x: center.x - Self.jointRadius, y: center.y - Self.jointRadius,
                    width: Self.jointRadius * 2, height: Self.jointRadius * 2))
                if keypoint.isUsable {
                    context.fill(joint, with: .color(.green))
                } else {
                    context.stroke(joint, with: .color(.red), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Frame-normalized keypoint → canvas point. Not clamped: a joint the model put in the
    /// letterbox pad reports outside [0, 1] (see `PoseKeypoint`), and drawing it off-canvas is
    /// the honest rendering of that.
    static func point(for keypoint: PoseKeypoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(keypoint.x) * size.width, y: CGFloat(keypoint.y) * size.height)
    }
}

private extension PoseKeypoint {
    var isUsable: Bool { confidence > PoseKeypoint.confidenceThreshold }
}
