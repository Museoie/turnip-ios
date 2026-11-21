import CoreMotion
import Foundation

/// How far the phone is rolled, as the camera's level indicator shows it (`docs/UIUX.md` §1b):
/// read off the same gravity vector the roll track is written from (`RollTrackRecorder`), but
/// in the screen's terms rather than the recorded picture's, since it is drawn on the screen.
struct CameraLevel: Equatable, Sendable {
    /// The phone's roll from upright portrait, in radians, clockwise as its holder sees the
    /// screen: −π to π. A line drawn on the screen turned by its negative lies along the
    /// real horizon.
    let rollRadians: Double

    /// The least of gravity (in g) that has to lie in the screen's plane for the indicator to
    /// show: below it the phone is nearer flat than upright, where a roll swings wildly with
    /// the smallest movement and says nothing about the horizon in the picture. Higher than
    /// `RollTrack.minimumInPlaneGravity`: a sample skipped in a file costs nothing, a line
    /// spinning on screen does.
    static let minimumInPlaneGravity = 0.5

    /// From `CMDeviceMotion.gravity`'s x (to the right of the portrait screen) and y (toward the
    /// top of the phone). Upright, gravity is (0, −1); rolled clockwise by θ it reads
    /// (sin θ, −cos θ). `nil` when the phone is too near flat (`minimumInPlaneGravity`).
    init?(gravityX: Double, gravityY: Double) {
        guard gravityX.isFinite, gravityY.isFinite,
              hypot(gravityX, gravityY) >= Self.minimumInPlaneGravity
        else { return nil }
        rollRadians = atan2(gravityX, -gravityY)
    }

    /// Which of the four ways to hold the phone the roll is nearest, in quarter turns clockwise
    /// from upright portrait: the take is leveled against that one, as the system camera's is.
    var quarterTurns: Int {
        Int((rollRadians / (.pi / 2)).rounded())
    }

    /// How far the phone is tilted from that nearest way of holding it, in degrees, clockwise
    /// positive: −45 to 45.
    var tiltDegrees: Double {
        (rollRadians - Double(quarterTurns) * .pi / 2) * 180 / .pi
    }
}

/// Feeds the camera preview's level indicator while a preview is on screen: gravity from the
/// roll recorder's motion updates, so the app runs one `CMMotionManager`, turned into a
/// `CameraLevel` and handed to each observer on the main actor.
///
/// Observers are held weakly by owner. Two previews can overlap for a moment, a closed camera
/// still sliding away under one just opened, so sampling runs while any is registered rather
/// than being started and stopped by one of them.
@MainActor
final class CameraLevelMonitor {
    private struct Observer {
        weak var owner: AnyObject?
        let onChange: (CameraLevel?) -> Void
    }

    private let recorder: RollTrackRecorder
    private var observers: [ObjectIdentifier: Observer] = [:]

    init(recorder: RollTrackRecorder) {
        self.recorder = recorder
    }

    /// Calls `onChange` with each reading, `nil` while the phone is too near flat to have one,
    /// until `owner` is removed or deallocated.
    func addObserver(_ owner: AnyObject, onChange: @escaping (CameraLevel?) -> Void) {
        let wasIdle = observers.isEmpty
        observers[ObjectIdentifier(owner)] = Observer(owner: owner, onChange: onChange)
        guard wasIdle else { return }
        recorder.observeGravity { [weak self] gravity in
            let level = CameraLevel(gravityX: gravity.x, gravityY: gravity.y)
            Task { @MainActor [weak self] in self?.publish(level) }
        }
    }

    func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
        stopIfIdle()
    }

    private func publish(_ level: CameraLevel?) {
        observers = observers.filter { $0.value.owner != nil }
        for observer in observers.values {
            observer.onChange(level)
        }
        stopIfIdle()
    }

    private func stopIfIdle() {
        guard observers.isEmpty else { return }
        recorder.observeGravity(nil)
    }
}
