import AVFoundation
import SwiftUI

/// Thin UIKit bridge for an `AVCaptureVideoPreviewLayer` — SwiftUI has no native camera
/// preview of its own — with the live pose skeleton drawn over it while recording.
///
/// The skeleton is drawn in UIKit rather than a SwiftUI overlay because only the preview
/// layer knows where a capture-device point lands on screen: `layerPointConverted` folds in
/// the connection's rotation, the front camera's mirroring and the aspect-fit letterbox, none of
/// which a SwiftUI `Canvas` over the view can see.
///
/// The video is aspect-fit and pinned to the top of the view rather than centered, so all of
/// the letterbox falls below the picture, behind the bottom controls. The preview layer can
/// only center, so it is a sublayer shifted up by the gap above the picture it reports; the
/// skeleton layers ride inside it, keeping `layerPointConverted`'s coordinates valid.
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
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.setLive(isLive)
        uiView.show(poseKeypoints)
    }

    final class PreviewUIView: UIView {
        private static let jointRadius: CGFloat = 5
        private static let fadeInDuration: TimeInterval = 0.3
        /// How long after going live the preview reveals itself even if the layer never
        /// reported rendering, so a missed `isPreviewing` change can't leave the camera black.
        private static let revealDeadline: TimeInterval = 1.5
        let videoPreviewLayer = AVCaptureVideoPreviewLayer()
        private let limbLayer = CAShapeLayer()
        private let jointLayer = CAShapeLayer()
        private var previewingObservation: NSKeyValueObservation?
        private var isLive = false
        private var isRevealed = false
        private var revealDeadlineWork: DispatchWorkItem?
        private var formatObserver: NSObjectProtocol?

        override init(frame: CGRect) {
            super.init(frame: frame)
            limbLayer.strokeColor = UIColor.systemGreen.cgColor
            limbLayer.lineWidth = 3
            limbLayer.lineCap = .round
            limbLayer.fillColor = nil
            jointLayer.fillColor = UIColor.systemGreen.cgColor
            videoPreviewLayer.videoGravity = .resizeAspect
            videoPreviewLayer.addSublayer(limbLayer)
            videoPreviewLayer.addSublayer(jointLayer)
            layer.addSublayer(videoPreviewLayer)
            isAccessibilityElement = false
            alpha = 0
            // Only the rise to true matters: a lens flip or format change can briefly stop
            // rendering, and hiding for that would blink the preview on every such tap. Hiding
            // is left to `setLive(false)`, which only leaving the page triggers.
            previewingObservation = videoPreviewLayer.observe(\.isPreviewing) { [weak self] layer, _ in
                guard layer.isPreviewing else { return }
                DispatchQueue.main.async {
                    self?.setNeedsLayout()
                    self?.revealIfLive()
                }
            }
            // A lens flip or format change can change the picture's aspect ratio, and with it
            // the gap the layer must be shifted by.
            formatObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureInput.Port.formatDescriptionDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.setNeedsLayout()
            }
        }

        deinit {
            previewingObservation?.invalidate()
            formatObserver.map(NotificationCenter.default.removeObserver)
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoPreviewLayer.frame = bounds
            // The whole capture frame, in metadata-output terms, is the unit rect.
            let picture = videoPreviewLayer.layerRectConverted(
                fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            if picture.minY.isFinite, picture.minY > 0 {
                videoPreviewLayer.frame = bounds.offsetBy(dx: 0, dy: -picture.minY)
            }
            limbLayer.frame = videoPreviewLayer.bounds
            jointLayer.frame = videoPreviewLayer.bounds
            CATransaction.commit()
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
