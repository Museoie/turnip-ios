import SwiftUI
import UIKit

/// The editor's crop gestures — pinch to zoom, two-finger rotate and one-finger drag, all able
/// to run at once — through UIKit's own recognizers rather than SwiftUI's.
///
/// SwiftUI's `MagnificationGesture` and `RotationGesture`, composed or attached side by side,
/// stop responding for the rest of the view's life once one of them recognizes a gesture the
/// other didn't (a pinch with no turn): every later pinch and turn is ignored, and when the
/// one-finger drag is composed with them, every later drag too. UIKit's recognizers reset
/// when the last finger lifts, whatever their siblings did.
///
/// Each callback reports one recognizer's cumulative value since its gesture began: live
/// while the fingers move, final when they lift, and `cancelled` when the system takes the
/// touches (a call, Control Center), where the gesture must leave nothing behind. The drag
/// only follows one finger, as SwiftUI's did: a two-finger gesture moves the video through
/// the pinch and turn alone.
struct CropGestureSurface: UIViewRepresentable {
    enum Phase<Value> {
        case changed(Value)
        case ended(Value)
        case cancelled
    }

    /// The drag's translation in the surface's own points.
    var onDrag: (Phase<CGSize>) -> Void
    /// The pinch's scale factor, 1 at its start.
    var onPinch: (Phase<CGFloat>) -> Void
    /// The turn in radians, clockwise positive — the sense `rotationEffect` and
    /// `CGAffineTransform(rotationAngle:)` both draw in a y-down space.
    var onRotate: (Phase<Double>) -> Void
    /// The first finger landing, before any of the three has recognized anything: where a
    /// gesture that has to know about every finger it saw starts counting.
    var onTouchDown: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.onTouchDown = onTouchDown
        let coordinator = context.coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        let rotation = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.rotate(_:)))
        for recognizer in [pan, pinch, rotation] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            // The view keeps seeing the touches the recognizers take, so its count of
            // fingers down stays right.
            recognizer.cancelsTouchesInView = false
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        context.coordinator.surface = self
        uiView.onTouchDown = onTouchDown
    }

    /// Counts the fingers down, to report the first one landing.
    final class TouchView: UIView {
        var onTouchDown: () -> Void = {}
        private var touchesDown = 0

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if touchesDown == 0 { onTouchDown() }
            touchesDown += touches.count
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            touchesDown = max(touchesDown - touches.count, 0)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            touchesDown = max(touchesDown - touches.count, 0)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The latest representable, so each report reaches the closures of the current
        /// render — they capture the stage's geometry as of that render.
        var surface: CropGestureSurface

        init(surface: CropGestureSurface) {
            self.surface = surface
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            report(recognizer.state, CGSize(width: translation.x, height: translation.y), to: surface.onDrag)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            report(recognizer.state, recognizer.scale, to: surface.onPinch)
        }

        @objc func rotate(_ recognizer: UIRotationGestureRecognizer) {
            report(recognizer.state, Double(recognizer.rotation), to: surface.onRotate)
        }

        private func report<Value>(
            _ state: UIGestureRecognizer.State, _ value: Value, to callback: (Phase<Value>) -> Void
        ) {
            switch state {
            case .began, .changed:
                callback(.changed(value))
            case .ended:
                callback(.ended(value))
            case .cancelled, .failed:
                callback(.cancelled)
            default:
                break
            }
        }

        /// The three run together, so a pinch can turn and slide at once; any other
        /// recognizer keeps UIKit's default exclusivity.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer.view === gestureRecognizer.view
        }
    }
}
