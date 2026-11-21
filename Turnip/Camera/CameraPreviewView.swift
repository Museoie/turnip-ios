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
/// Over the picture, as the system camera draws them: a grid of thirds, and at its center a
/// level, a line along the real horizon between two short marks fixed to the screen, which
/// joins them and turns yellow when the phone is level (`CameraLevel`). Both are drawn here for
/// the same reason the skeleton is: only this view knows where the picture sits.
///
/// The preview stays fully transparent — showing the black behind it — until the layer is
/// actually rendering frames, then fades in once. Left to itself the layer shows its last
/// frame from the previous visit while the camera slides in, blanks to black when the session
/// restarts, and only then shows live video: a flicker on every visit to the camera.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// False while the session is stopped or stopping. Hides the preview at once so a stale
    /// frame never shows; the next frames the layer renders fade it back in.
    var isLive = true
    /// In capture-device coordinates (the unrotated sensor picture, 0...1), one skeleton per
    /// person drawn. Empty hides them.
    var poseSkeletons: [[PoseKeypoint]] = []
    /// Where the level indicator's readings come from; `nil` shows the grid alone.
    var levelMonitor: CameraLevelMonitor?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.levelMonitor = levelMonitor
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.setLive(isLive)
        uiView.show(poseSkeletons)
    }

    final class PreviewUIView: UIView {
        private static let jointRadius: CGFloat = 5
        private static let fadeInDuration: TimeInterval = 0.3
        /// How long after going live the preview reveals itself even if the layer never
        /// reported rendering, so a missed `isPreviewing` change can't leave the camera black.
        private static let revealDeadline: TimeInterval = 1.5
        /// The level's center line, in points, the marks either side of it, and the gap between.
        private static let levelLineLength: CGFloat = 72
        private static let levelMarkLength: CGFloat = 20
        private static let levelGap: CGFloat = 6
        /// Within this many degrees of level the indicator reads level, and it stays so until
        /// the tilt passes the second: without the gap a hand held at the threshold flickers.
        private static let levelEnterDegrees = 1.0
        private static let levelExitDegrees = 1.5
        let videoPreviewLayer = AVCaptureVideoPreviewLayer()
        /// Set once, as the view is made. Readings arrive only while the preview is live.
        var levelMonitor: CameraLevelMonitor?
        private let gridLayer = CAShapeLayer()
        /// Holds the level's two layers at the picture's center.
        private let levelLayer = CALayer()
        private let levelMarksLayer = CAShapeLayer()
        private let levelLineLayer = CAShapeLayer()
        private var isLevel = false
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
            gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
            gridLayer.lineWidth = 1 / UIScreen.main.scale
            gridLayer.fillColor = nil
            videoPreviewLayer.addSublayer(gridLayer)
            for line in [levelMarksLayer, levelLineLayer] {
                line.strokeColor = UIColor.white.cgColor
                line.lineWidth = 1.5
                line.fillColor = nil
                // The picture behind can be as bright as the line.
                line.shadowColor = UIColor.black.cgColor
                line.shadowOpacity = 0.5
                line.shadowRadius = 1
                line.shadowOffset = .zero
                levelLayer.addSublayer(line)
            }
            levelMarksLayer.path = Self.levelMarksPath()
            levelLineLayer.path = Self.levelLinePath()
            levelLayer.isHidden = true
            videoPreviewLayer.addSublayer(levelLayer)
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
                levelMonitor?.removeObserver(self)
                show(level: nil)
                return
            }
            levelMonitor?.addObserver(self) { [weak self] level in
                self?.show(level: level)
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
            // Until the layer has a connection it reports no picture, or one that isn't a rect.
            let hasPicture = picture.minX.isFinite && picture.minY.isFinite
                && picture.width.isFinite && picture.height.isFinite
                && picture.width > 0 && picture.height > 0
            gridLayer.frame = videoPreviewLayer.bounds
            gridLayer.path = hasPicture ? Self.gridPath(in: picture) : nil
            levelLayer.position = hasPicture
                ? CGPoint(x: picture.midX, y: picture.midY)
                : CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        /// The two lines each way that cut `picture` into thirds.
        private static func gridPath(in picture: CGRect) -> CGPath {
            let path = CGMutablePath()
            for third in [CGFloat(1) / 3, CGFloat(2) / 3] {
                let x = picture.minX + picture.width * third
                let y = picture.minY + picture.height * third
                path.move(to: CGPoint(x: x, y: picture.minY))
                path.addLine(to: CGPoint(x: x, y: picture.maxY))
                path.move(to: CGPoint(x: picture.minX, y: y))
                path.addLine(to: CGPoint(x: picture.maxX, y: y))
            }
            return path
        }

        /// The level's center line, about the origin.
        private static func levelLinePath() -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -levelLineLength / 2, y: 0))
            path.addLine(to: CGPoint(x: levelLineLength / 2, y: 0))
            return path
        }

        /// The marks either side of the center line, a gap away from its ends.
        private static func levelMarksPath() -> CGPath {
            let path = CGMutablePath()
            let inner = levelLineLength / 2 + levelGap
            for side: CGFloat in [-1, 1] {
                path.move(to: CGPoint(x: side * inner, y: 0))
                path.addLine(to: CGPoint(x: side * (inner + levelMarkLength), y: 0))
            }
            return path
        }

        /// Turns the level to `level`, or hides it for `nil`. The marks lie along the screen in
        /// whichever of its four directions the phone is held nearest; the line between them
        /// lies along the real horizon, so it leans the way the picture will, and joins them,
        /// yellow, when the phone is level. Implicit animations are off: at thirty readings a
        /// second an animated turn would always be mid-tween and lag the hand.
        func show(level: CameraLevel?) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard let level else {
                levelLayer.isHidden = true
                isLevel = false
                return
            }
            isLevel = abs(level.tiltDegrees) <= (isLevel ? Self.levelExitDegrees : Self.levelEnterDegrees)
            let color = (isLevel ? UIColor.systemYellow : UIColor.white).cgColor
            levelMarksLayer.strokeColor = color
            levelLineLayer.strokeColor = color
            // A positive angle turns a layer clockwise on screen. The phone rolled clockwise shows
            // the world, the horizon with it, turned the other way.
            let held = -CGFloat(level.quarterTurns) * .pi / 2
            levelMarksLayer.setAffineTransform(CGAffineTransform(rotationAngle: held))
            levelLineLayer.setAffineTransform(
                CGAffineTransform(rotationAngle: isLevel ? held : -CGFloat(level.rollRadians)))
            levelLayer.isHidden = false
        }

        /// Redraws the skeletons. Implicit layer animations are disabled: at ten poses a second an
        /// animated path would always be mid-tween, smearing the joints between two poses.
        func show(_ skeletons: [[PoseKeypoint]]) {
            let previewLayer = videoPreviewLayer
            let limbs = CGMutablePath()
            let joints = CGMutablePath()
            for keypoints in skeletons {
                let geometry = LivePoseOverlayGeometry(keypoints: keypoints) { keypoint in
                    previewLayer.layerPointConverted(
                        fromCaptureDevicePoint: CGPoint(x: CGFloat(keypoint.x), y: CGFloat(keypoint.y)))
                }
                for limb in geometry.limbs {
                    limbs.move(to: limb.start)
                    limbs.addLine(to: limb.end)
                }
                for joint in geometry.joints {
                    joints.addEllipse(in: CGRect(
                        x: joint.x - Self.jointRadius, y: joint.y - Self.jointRadius,
                        width: Self.jointRadius * 2, height: Self.jointRadius * 2))
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            limbLayer.path = limbs
            jointLayer.path = joints
            CATransaction.commit()
        }
    }
}
