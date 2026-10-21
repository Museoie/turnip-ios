import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

/// A follow crop's movement in the editor's preview: how far the picture is shifted, in the
/// source's displayed pixels, at each frame the player can show — the crop's center moved
/// onto the clip's crop center, before the zoom and turn apply about it.
///
/// The shift steps once per source frame, on the frame's own presentation time, rather than
/// gliding between frames: the picture itself changes only once per frame, and a pan that
/// moves on every display refresh drifts up to half a frame off it — the athlete visibly
/// shakes inside the marker (`docs/DESIGN.md` step 6, "Editor preview").
struct FollowPan: Equatable {
    /// The shift before the first step.
    let initial: CGPoint
    /// Each step's frame time and the shift from then on, in time order.
    let steps: [(time: TimeInterval, shift: CGPoint)]

    /// `frames` are the presentation times across the crop's moving span
    /// (`VideoFrameTimes.frames(across:)`); a crop that never moves has no steps.
    init(crop: FollowCrop, cropCenter: CGPoint, frames: [TimeInterval]) {
        let path = crop.path
        func shift(at time: TimeInterval) -> CGPoint {
            let center = path.center(at: time)
            return CGPoint(x: cropCenter.x - center.x, y: cropCenter.y - center.y)
        }
        initial = shift(at: path.movingSpan?.lowerBound ?? 0)
        steps = path.movingSpan == nil ? [] : frames.map { ($0, shift(at: $0)) }
    }

    func shift(at time: TimeInterval) -> CGPoint {
        steps.last { $0.time <= time }?.shift ?? initial
    }

    static func == (lhs: FollowPan, rhs: FollowPan) -> Bool {
        lhs.initial == rhs.initial
            && lhs.steps.count == rhs.steps.count
            && zip(lhs.steps, rhs.steps).allSatisfy { $0.time == $1.time && $0.shift == $1.shift }
    }
}

/// A change to the preview's pan that eases in rather than cutting: an automatic change or a
/// mode switch moves the picture from where it is to where the new pan has it, over the same
/// 0.4 s ease the zoom and turn animate on (`docs/UIUX.md` § "An automatic change moves, it
/// never cuts"). `id` changes once per such change; `time` is the source time the two pans
/// are compared at — where the playhead is, or is about to be.
struct FollowPanTransition: Equatable {
    var id = 0
    var time: TimeInterval = 0
}

/// The editor's video layer, inside an `AVSynchronizedLayer` on the player's item so the
/// follow pan (`FollowPan`) runs on the item's own clock: it pauses, loops, scrubs and plays
/// with the picture, with no work on the main thread per frame. The pan is a discrete
/// keyframe animation of the video layer's position, one value per source frame. With no pan
/// the video sits still, as Still mode draws it. Shared by the editor's stage and the
/// expansion flight's card, each with its own layer on the same player.
///
/// Only the surface on screen keeps a synchronized layer (`isSynchronized`): the card while it
/// flies, the editor once the card has landed — two on one item put the second a frame off.
/// Known limit, seen on the iPhone 15 simulator (iOS 26.2): once a player has had a second
/// `AVPlayerLayer`, or its one layer has moved to another view, the pan steps a display
/// refresh away from the picture on about half the frames it plays, whichever layer is on
/// screen. The flight's card is that second layer, so the editor opened from the Clip List
/// shows it there; opened alone, the pan holds to the picture. Still to check on a device.
struct EditorPlayerView: UIViewRepresentable {
    let player: AVPlayer
    /// The displayed frame's size in pixels, which `pan`'s shifts are in.
    let videoSize: CGSize
    let pan: FollowPan?
    /// The item's duration, which the pan's key times are fractions of.
    var duration: TimeInterval?
    var transition = FollowPanTransition()
    var isSynchronized = true
    var onReadyForDisplay: (() -> Void)?

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.isSynchronized = isSynchronized
        view.attach(player)
        view.onReadyForDisplay = onReadyForDisplay
        // A surface mounting after a transition shows the pan where it is, not easing in.
        view.seedTransition(transition)
        view.update(videoSize: videoSize, pan: pan, duration: duration, transition: transition)
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        view.setSynchronized(isSynchronized)
        view.attach(player)
        view.onReadyForDisplay = onReadyForDisplay
        view.update(videoSize: videoSize, pan: pan, duration: duration, transition: transition)
    }

    final class PlayerContainerView: UIView {
        var onReadyForDisplay: (() -> Void)?
        var isSynchronized = true
        /// Carries the eased hand-over between two pans, on the wall clock — outside the
        /// synchronized layer, whose sublayers run on the item's.
        private let easeLayer = CALayer()
        private var syncLayer: AVSynchronizedLayer?
        private let playerLayer = AVPlayerLayer()
        private var player: AVPlayer?
        private var itemObservation: NSKeyValueObservation?
        private var readyObservation: NSKeyValueObservation?
        private var videoSize: CGSize = .zero
        private var duration: TimeInterval?
        private var pan: FollowPan?
        private var transition = FollowPanTransition()
        private var installedSize: CGSize = .zero

        private static let panKey = "follow-pan"
        private static let easeKey = "follow-ease"

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(easeLayer)
            playerLayer.videoGravity = .resizeAspect
            // `AVPlayerLayer` opts into extended dynamic range by default on an EDR display,
            // which reads as blown out next to the SDR posters and the Photos player.
            if #available(iOS 17.0, *) {
                playerLayer.wantsExtendedDynamicRangeContent = false
            }
            easeLayer.addSublayer(playerLayer)
            readyObservation = playerLayer.observe(
                \.isReadyForDisplay, options: [.initial, .new]
            ) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { self?.onReadyForDisplay?() }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        func attach(_ player: AVPlayer) {
            guard self.player !== player else { return }
            self.player = player
            playerLayer.player = player
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                DispatchQueue.main.async { self?.adopt(player.currentItem) }
            }
        }

        func setSynchronized(_ synchronized: Bool) {
            guard synchronized != isSynchronized else { return }
            isSynchronized = synchronized
            adopt(player?.currentItem)
        }

        func seedTransition(_ transition: FollowPanTransition) {
            self.transition = transition
        }

        func update(videoSize: CGSize, pan: FollowPan?, duration: TimeInterval?, transition: FollowPanTransition) {
            let previous = self.pan
            let isNewTransition = transition.id != self.transition.id
            let needsInstall = pan != previous || videoSize != self.videoSize || duration != self.duration
            self.videoSize = videoSize
            self.duration = duration
            self.transition = transition
            guard needsInstall else { return }
            self.pan = pan
            installPan()
            if isNewTransition {
                ease(from: previous, at: transition.time)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            easeLayer.frame = bounds
            syncLayer?.frame = bounds
            playerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
            if bounds.size != installedSize {
                installPan()
            }
        }

        /// A new item needs a new synchronized layer: the layer is bound to the item it was
        /// made with.
        private func adopt(_ item: AVPlayerItem?) {
            let item = isSynchronized ? item : nil
            guard syncLayer?.playerItem !== item else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            syncLayer?.removeFromSuperlayer()
            syncLayer = nil
            if let item {
                let sync = AVSynchronizedLayer(playerItem: item)
                sync.frame = bounds
                easeLayer.addSublayer(sync)
                sync.addSublayer(playerLayer)
                syncLayer = sync
            } else {
                easeLayer.addSublayer(playerLayer)
            }
            CATransaction.commit()
            installPan()
        }

        /// On-screen points per displayed pixel.
        private var pointsPerPixel: CGFloat {
            videoSize.width > 0 ? bounds.width / videoSize.width : 0
        }

        private func installPan() {
            installedSize = bounds.size
            playerLayer.removeAnimation(forKey: Self.panKey)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let scale = pointsPerPixel
            func position(_ shift: CGPoint) -> CGPoint {
                CGPoint(x: center.x + shift.x * scale, y: center.y + shift.y * scale)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.position = position(pan?.initial ?? .zero)
            CATransaction.commit()
            guard let pan, !pan.steps.isEmpty, syncLayer != nil,
                  let duration, duration.isFinite, duration > 0
            else { return }
            let animation = CAKeyframeAnimation(keyPath: "position")
            animation.calculationMode = .discrete
            // Discrete keyframes hold each value until the next key time, so there is one
            // more key time than values: the first value holds from zero to the first frame.
            animation.values = ([pan.initial] + pan.steps.map(\.shift)).map { NSValue(cgPoint: position($0)) }
            animation.keyTimes = ([0] + pan.steps.map { min(max($0.time / duration, 0), 1) } + [1])
                .map { NSNumber(value: $0) }
            animation.duration = duration
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.isRemovedOnCompletion = false
            animation.fillMode = .both
            playerLayer.add(animation, forKey: Self.panKey)
        }

        /// Starts the picture where `previous` had it at `time` and eases it onto the
        /// current pan, adding to whatever ease is still running.
        private func ease(from previous: FollowPan?, at time: TimeInterval) {
            let old = previous?.shift(at: time) ?? .zero
            let new = pan?.shift(at: time) ?? .zero
            let scale = pointsPerPixel
            var start = CGPoint(x: (old.x - new.x) * scale, y: (old.y - new.y) * scale)
            if let running = easeLayer.presentation(), easeLayer.animation(forKey: Self.easeKey) != nil {
                start.x += running.position.x - easeLayer.position.x
                start.y += running.position.y - easeLayer.position.y
            }
            guard abs(start.x) > 0.01 || abs(start.y) > 0.01 else { return }
            let animation = CABasicAnimation(keyPath: "position")
            animation.isAdditive = true
            animation.fromValue = NSValue(cgPoint: start)
            animation.toValue = NSValue(cgPoint: .zero)
            animation.duration = ClipEditorViewModel.fitDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            easeLayer.add(animation, forKey: Self.easeKey)
        }
    }
}
