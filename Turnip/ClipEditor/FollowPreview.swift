import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

/// A follow crop's movement in the editor's preview: how far the picture is shifted, in the
/// source's displayed pixels, at each frame the player can show — the crop's center moved
/// onto the clip's crop center, before the zoom and turn apply about it.
///
/// The shift steps once per source frame, on the frame's own presentation time: the preview
/// draws it into the frames themselves (`FollowPreviewComposition`).
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

    private init(initial: CGPoint, steps: [(time: TimeInterval, shift: CGPoint)]) {
        self.initial = initial
        self.steps = steps
    }

    func shift(at time: TimeInterval) -> CGPoint {
        steps.last { $0.time <= time }?.shift ?? initial
    }

    /// The same pan with the picture moved a further `offset` at every moment.
    func moved(by offset: CGPoint) -> FollowPan {
        func move(_ shift: CGPoint) -> CGPoint { CGPoint(x: shift.x + offset.x, y: shift.y + offset.y) }
        return FollowPan(initial: move(initial), steps: steps.map { ($0.time, move($0.shift)) })
    }

    static func == (lhs: FollowPan, rhs: FollowPan) -> Bool {
        lhs.initial == rhs.initial
            && lhs.steps.count == rhs.steps.count
            && zip(lhs.steps, rhs.steps).allSatisfy { $0.time == $1.time && $0.shift == $1.shift }
    }
}

/// What the preview's frames are drawn with: a follow pan held steady (`nil` draws the frame
/// unshifted, as Still does), or an ease from what the frames showed onto a new one
/// (`docs/UIUX.md` § "An automatic change moves, it never cuts").
///
/// The ease is in the frames too, never in a layer animation over them: a layer animation and
/// a video frame can't be made to land on the same display refresh, so a hand-over between
/// the two shows one frame wrong. It runs on the item's clock from `anchor`, the frame on
/// screen when it starts, so it plays with the picture and freezes with it; while the player is
/// paused the editor steps `progress` on the wall clock and redraws the frame on screen
/// (`ClipEditorViewModel`). Frames before the anchor show the new pan: only a loop or a seek
/// reaches them, and either one ends the ease.
indirect enum PreviewPan: Equatable {
    case steady(FollowPan?)
    /// From `from` onto `target` along the ease curve over `easeDuration` of item time,
    /// `progress` (0 to 1) of the way at `anchor` and moving on with item time after it.
    case easing(from: PreviewPan, target: FollowPan?, anchor: TimeInterval, progress: Double)

    static let easeDuration = ClipEditorViewModel.fitDuration

    /// The pan this one is, or is easing onto.
    var target: FollowPan? {
        switch self {
        case .steady(let pan): return pan
        case .easing(_, let target, _, _): return target
        }
    }

    var isEasing: Bool {
        if case .easing = self { return true }
        return false
    }

    /// The picture's shift at `time`, in displayed pixels.
    func shift(at time: TimeInterval) -> CGPoint {
        switch self {
        case .steady(let pan):
            return pan?.shift(at: time) ?? .zero
        case let .easing(from, target, anchor, progress):
            let end = target?.shift(at: time) ?? .zero
            guard time >= anchor else { return end }
            let travel = Self.easeInOut(min(progress + (time - anchor) / Self.easeDuration, 1))
            let start = from.shift(at: time)
            return CGPoint(x: start.x + (end.x - start.x) * travel, y: start.y + (end.y - start.y) * travel)
        }
    }

    /// The ease's progress at `time` on the item's clock, if this is easing; past 1 once it has
    /// arrived.
    func progress(at time: TimeInterval) -> Double? {
        guard case let .easing(_, _, anchor, progress) = self else { return nil }
        return progress + max(time - anchor, 0) / Self.easeDuration
    }

    /// Every pan drawn, for the canvas's reach.
    var pans: [FollowPan] {
        switch self {
        case .steady(let pan): return pan.map { [$0] } ?? []
        case let .easing(from, target, _, _): return from.pans + (target.map { [$0] } ?? [])
        }
    }

    /// The stretches of item time an ease is still under way in, where every frame needs its own
    /// shift.
    var easingSpans: [ClosedRange<TimeInterval>] {
        guard case let .easing(from, _, anchor, progress) = self else { return [] }
        let span = anchor...(anchor + max(1 - progress, 0) * Self.easeDuration)
        return from.easingSpans + [span]
    }

    /// The zoom's ease (SwiftUI's `.easeInOut`, a cubic Bézier through (0.42, 0) and (0.58, 1)),
    /// so the pan and the zoom move as one.
    static func easeInOut(_ fraction: Double) -> Double {
        // Exactly the ends at the ends: an ease's first frame is the frame on screen, unchanged.
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }
        let x = fraction
        func bezier(_ along: Double, _ first: Double, _ second: Double) -> Double {
            let rest = 1 - along
            return 3 * rest * rest * along * first + 3 * rest * along * along * second + along * along * along
        }
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if bezier(mid, 0.42, 0.58) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, 0, 1)
    }
}

/// The preview's frames with the pan drawn into them: an `AVVideoComposition` on the editor's
/// item that places each source frame, at its own presentation time, shifted by the pan for
/// that frame. The picture and its pan are one image, so they can't drift apart on any display;
/// a synchronized layer animation keyed to the item's clock lands a display refresh off the
/// picture on some playback passes on a device, depending on the pass's phase against the
/// display (`docs/DESIGN.md` step 6, "Editor preview").
///
/// The canvas is the displayed frame padded on each side by as far as a pan could move it
/// (`padding(videoSize:cropCenter:pans:)`), so a shifted frame is never cut; the player layer is
/// laid out padded by the same amount, which puts the unshifted frame exactly on the video
/// view's own bounds. Still plays through the same canvas unshifted, so a pan change or a mode
/// switch swaps the composition but never the layout. A canvas past `maximumCanvasDimension`
/// renders scaled down, which the layer scales back up.
struct FollowPreviewComposition {
    let videoComposition: AVVideoComposition
    /// The canvas's render scale, 1 unless the padded canvas is too large to draw at full size.
    let renderScale: CGFloat

    static let maximumCanvasDimension: CGFloat = 4096

    /// How far the canvas reaches past the displayed frame on each side, in displayed pixels: as
    /// far as the frame's farther edge is from the crop's center, which bounds a pan that keeps
    /// the curve inside the frame, or further where one of `pans` already reaches further.
    static func padding(videoSize: CGSize, cropCenter: CGPoint, pans: [FollowPan]) -> CGSize {
        let shifts = pans.flatMap { [$0.initial] + $0.steps.map(\.shift) }
        let width = max(cropCenter.x, videoSize.width - cropCenter.x, shifts.map { abs($0.x) }.max() ?? 0)
        let height = max(cropCenter.y, videoSize.height - cropCenter.y, shifts.map { abs($0.y) }.max() ?? 0)
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    /// `frames` are the source's frame times across `pan`'s easing spans, where the shift
    /// changes on every frame; elsewhere it changes only on its pans' own steps.
    init(
        pan: PreviewPan, frames: [TimeInterval], padding: CGSize, geometry: VideoTrackGeometry,
        trackID: CMPersistentTrackID, duration: CMTime, frameRate: Double
    ) {
        let size = geometry.displayedSize
        let canvas = CGSize(width: size.width + 2 * padding.width, height: size.height + 2 * padding.height)
        let scale = min(1, Self.maximumCanvasDimension / max(canvas.width, canvas.height, 1))
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(
            width: (canvas.width * scale).rounded(.up), height: (canvas.height * scale).rounded(.up))
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate.rounded(), 1)))
        // Renders once per source frame, at the source's own times, rather than on a fixed grid.
        composition.sourceTrackIDForFrameTiming = trackID
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction()
        layerInstruction.trackID = trackID
        var times = Set(pan.pans.flatMap { $0.steps.map(\.time) })
        for span in pan.easingSpans {
            times.insert(span.lowerBound)
            times.formUnion(frames.filter { span.contains($0) })
        }
        layerInstruction.setTransform(Self.transform(pan.shift(at: 0), geometry, padding, scale), at: .zero)
        for time in times.sorted() where time > 0 {
            // Just before the frame's own time, so a rounding up never leaves that frame on the
            // previous transform.
            let value = CMTimeValue(((time - 0.0005) * 90_000).rounded(.down))
            layerInstruction.setTransform(
                Self.transform(pan.shift(at: time), geometry, padding, scale),
                at: CMTime(value: max(value, 1), timescale: 90_000))
        }
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        videoComposition = composition
        renderScale = scale
    }

    /// Uprights the source frame, moves it onto the canvas by the padding and `shift`, and
    /// scales the canvas to its render size.
    static func transform(
        _ shift: CGPoint, _ geometry: VideoTrackGeometry, _ padding: CGSize, _ scale: CGFloat
    ) -> CGAffineTransform {
        geometry.uprightTransform
            .concatenating(CGAffineTransform(translationX: padding.width + shift.x, y: padding.height + shift.y))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// The editor's video layer, laid out over the preview composition's padded canvas
/// (`FollowPreviewComposition`), so the frame itself sits on the view's bounds; the pan and its
/// eases are already in the frames. Shared by the editor's stage and the expansion flight's
/// card, each with its own layer on the same player.
struct EditorPlayerView: UIViewRepresentable {
    let player: AVPlayer
    /// The displayed frame's size in pixels, which `padding` is in.
    let videoSize: CGSize
    /// The preview composition's canvas padding (`FollowPreviewComposition.padding`).
    var padding: CGSize = .zero
    var onReadyForDisplay: (() -> Void)?

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.attach(player)
        view.onReadyForDisplay = onReadyForDisplay
        view.update(videoSize: videoSize, padding: padding)
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        view.attach(player)
        view.onReadyForDisplay = onReadyForDisplay
        view.update(videoSize: videoSize, padding: padding)
    }

    final class PlayerContainerView: UIView {
        var onReadyForDisplay: (() -> Void)?
        private let playerLayer = AVPlayerLayer()
        private var player: AVPlayer?
        private var readyObservation: NSKeyValueObservation?
        private var videoSize: CGSize = .zero
        private var padding: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.videoGravity = .resizeAspect
            // `AVPlayerLayer` opts into extended dynamic range by default on an EDR display,
            // which reads as blown out next to the SDR posters and the Photos player.
            if #available(iOS 17.0, *) {
                playerLayer.wantsExtendedDynamicRangeContent = false
            }
            layer.addSublayer(playerLayer)
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
        }

        func update(videoSize: CGSize, padding: CGSize) {
            guard videoSize != self.videoSize || padding != self.padding else { return }
            self.videoSize = videoSize
            self.padding = padding
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let scale = videoSize.width > 0 ? bounds.width / videoSize.width : 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds.insetBy(dx: -padding.width * scale, dy: -padding.height * scale)
            CATransaction.commit()
        }
    }
}
