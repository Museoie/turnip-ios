import AVFoundation
import SwiftUI

/// Thin UIKit bridge for an `AVCaptureVideoPreviewLayer` — SwiftUI has no native camera
/// preview of its own — with the live pose skeleton drawn over it while recording.
///
/// The skeleton is drawn in UIKit rather than a SwiftUI overlay because only the preview
/// layer knows where a capture-device point lands on screen: `layerPointConverted` folds in
/// the connection's rotation, the front camera's mirroring and the aspect-fill crop, none of
/// which a SwiftUI `Canvas` over the view can see.
///
/// The preview stays fully transparent — showing the black behind it — until the layer is
/// actually rendering frames, then fades in once. Left to itself the layer shows its last
/// frame from the previous visit while the page slides in, blanks to black when the session
/// restarts, and only then shows live video: a flicker on every visit to the camera page.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// False while the session is stopped or stopping. Hides the preview at once so a stale
    /// frame never shows; the next frames the layer renders fade it back in.
    var isLive = true
    /// In capture-device coordinates (the unrotated sensor picture, 0...1). Empty hides it.
    var poseKeypoints: [PoseKeypoint] = []

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.setLive(isLive)
        uiView.show(poseKeypoints)
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        private static let jointRadius: CGFloat = 5
        private static let fadeInDuration: TimeInterval = 0.3
        /// How long after going live the preview reveals itself even if the layer never
        /// reported rendering, so a missed `isPreviewing` change can't leave the camera black.
        private static let revealDeadline: TimeInterval = 1.5
        private let limbLayer = CAShapeLayer()
        private let jointLayer = CAShapeLayer()
        private var previewingObservation: NSKeyValueObservation?
        private var isLive = false
        private var isRevealed = false
        private var revealDeadlineWork: DispatchWorkItem?

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
                fatalError("PreviewUIView.layerClass guarantees an AVCaptureVideoPreviewLayer")
            }
            return previewLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            limbLayer.strokeColor = UIColor.systemGreen.cgColor
            limbLayer.lineWidth = 3
            limbLayer.lineCap = .round
            limbLayer.fillColor = nil
            jointLayer.fillColor = UIColor.systemGreen.cgColor
            layer.addSublayer(limbLayer)
            layer.addSublayer(jointLayer)
            isAccessibilityElement = false
            alpha = 0
            // Only the rise to true matters: a lens flip or format change can briefly stop
            // rendering, and hiding for that would blink the preview on every such tap. Hiding
            // is left to `setLive(false)`, which only leaving the page triggers.
            previewingObservation = videoPreviewLayer.observe(\.isPreviewing) { [weak self] layer, _ in
                guard layer.isPreviewing else { return }
                DispatchQueue.main.async { self?.revealIfLive() }
            }
        }

        deinit {
            previewingObservation?.invalidate()
            revealDeadlineWork?.cancel()
        }

        func setLive(_ live: Bool) {
            guard live != isLive else { return }
            isLive = live
            revealDeadlineWork?.cancel()
            guard live else {
                layer.removeAllAnimations()
                alpha = 0
                isRevealed = false
                return
            }
            let deadline = DispatchWorkItem { [weak self] in self?.revealIfLive() }
            revealDeadlineWork = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDeadline, execute: deadline)
        }

        private func revealIfLive() {
            guard isLive, !isRevealed else { return }
            isRevealed = true
            revealDeadlineWork?.cancel()
            UIView.animate(withDuration: Self.fadeInDuration, delay: 0, options: [.curveEaseOut]) {
                self.alpha = 1
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("PreviewUIView is built in code")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            limbLayer.frame = bounds
            jointLayer.frame = bounds
        }

        /// Redraws the skeleton. Implicit layer animations are disabled: at ten poses a second an
        /// animated path would always be mid-tween, smearing the joints between two poses.
        func show(_ keypoints: [PoseKeypoint]) {
            let previewLayer = videoPreviewLayer
            let geometry = LivePoseOverlayGeometry(keypoints: keypoints) { keypoint in
                previewLayer.layerPointConverted(
                    fromCaptureDevicePoint: CGPoint(x: CGFloat(keypoint.x), y: CGFloat(keypoint.y)))
            }
            let limbs = CGMutablePath()
            for limb in geometry.limbs {
                limbs.move(to: limb.start)
                limbs.addLine(to: limb.end)
            }
            let joints = CGMutablePath()
            for joint in geometry.joints {
                joints.addEllipse(in: CGRect(
                    x: joint.x - Self.jointRadius, y: joint.y - Self.jointRadius,
                    width: Self.jointRadius * 2, height: Self.jointRadius * 2))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            limbLayer.path = limbs
            jointLayer.path = joints
            CATransaction.commit()
        }
    }
}
