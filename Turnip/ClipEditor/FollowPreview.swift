import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

/// How the preview draws one frame: the picture shifted, in the source's displayed pixels, so
/// that the framing's center lands on the clip's crop center, then zoomed and turned about it —
/// the order a follow crop is exported in (`ClipExportTransform.make(followCrop:…)`).
struct PreviewFraming: Equatable {
    var shift: CGPoint
    /// `CropAdjustment.scale`'s meaning.
    var scale: CGFloat
    var rotationRadians: Double

    static let identity = PreviewFraming(shift: .zero, scale: 1, rotationRadians: 0)
}

/// A follow crop's movement in the editor's preview: how the picture is drawn at each frame the
/// player can show — the crop's center at that frame moved onto the clip's crop center, at that
/// frame's zoom and turn.
///
/// It steps once per source frame, on the frame's own presentation time: the preview draws the
/// picture with the frame it shows (`EditorPlayerView`).
struct FollowPan: Equatable {
    /// The framing before the first step.
    let initial: PreviewFraming
    /// Each step's frame time and the framing from then on, in time order.
    let steps: [(time: TimeInterval, framing: PreviewFraming)]

    /// `frames` are the presentation times across the crop's moving span
    /// (`VideoFrameTimes.frames(across:)`); a crop that never moves has no steps.
    init(crop: FollowCrop, cropCenter: CGPoint, frames: [TimeInterval]) {
        let path = crop.path
        func framing(at time: TimeInterval) -> PreviewFraming {
            let framing = path.framing(at: time)
            return PreviewFraming(
                shift: CGPoint(x: cropCenter.x - framing.center.x, y: cropCenter.y - framing.center.y),
                scale: framing.scale, rotationRadians: framing.rotationRadians)
        }
        initial = framing(at: path.movingSpan?.lowerBound ?? 0)
        steps = path.movingSpan == nil ? [] : frames.map { ($0, framing(at: $0)) }
    }

    func framing(at time: TimeInterval) -> PreviewFraming {
        steps.last { $0.time <= time }?.framing ?? initial
    }

    static func == (lhs: FollowPan, rhs: FollowPan) -> Bool {
        lhs.initial == rhs.initial
            && lhs.steps.count == rhs.steps.count
            && zip(lhs.steps, rhs.steps).allSatisfy { $0.time == $1.time && $0.framing == $1.framing }
    }
}

/// How much of each pan the preview draws, keyed by the pan's generation
/// (`PreviewPanBlend.pans`). At rest one generation has all of it; an ease
/// (`docs/UIUX.md` § "An automatic change moves, it never cuts") hands it to a new generation
/// along SwiftUI's own animation of this value, so the pan, the zoom and the turn move onto the
/// new generation's by the same curve on the same frame — an ease that interrupts another
/// included, since SwiftUI adds the animations of a vector value the way it adds a scale's.
struct PreviewPanWeights: VectorArithmetic {
    /// A missing generation weighs nothing.
    private(set) var values: [Int: Double]

    init(_ values: [Int: Double] = [:]) {
        self.values = values.filter { $0.value != 0 }
    }

    static var zero: PreviewPanWeights { PreviewPanWeights() }

    static func + (lhs: PreviewPanWeights, rhs: PreviewPanWeights) -> PreviewPanWeights {
        PreviewPanWeights(lhs.values.merging(rhs.values, uniquingKeysWith: +))
    }

    static func - (lhs: PreviewPanWeights, rhs: PreviewPanWeights) -> PreviewPanWeights {
        PreviewPanWeights(lhs.values.merging(rhs.values.mapValues { -$0 }, uniquingKeysWith: +))
    }

    mutating func scale(by rhs: Double) {
        self = PreviewPanWeights(values.mapValues { $0 * rhs })
    }

    var magnitudeSquared: Double {
        values.values.reduce(0) { $0 + $1 * $1 }
    }
}

/// What the preview draws the picture with: a blend of follow pans, `nil` among them meaning the
/// unshifted frame, before the follow crop is in hand. Each frame's framing is worked out at the
/// frame's own presentation time, so the pan, the zoom and the turn never step on a different
/// refresh from their frame.
///
/// The blend weighs each generation's shift, zoom and turn and adds them up, so an ease
/// (`PreviewPanWeights`) moves all three along SwiftUI's curve together, the way SwiftUI used to
/// animate a zoom and turn of the whole clip.
struct PreviewPanBlend: Equatable {
    /// The pans by generation; a generation without one draws the unshifted frame.
    var pans: [Int: FollowPan]
    var weights: PreviewPanWeights

    /// The picture's framing for the frame presented at `time`, with a live pinch's `gestureScale`
    /// and a live turn's `gestureRotation` on top; the framing keeps its center through both.
    func framing(at time: TimeInterval, gestureScale: CGFloat = 1, gestureRotation: Double = 0) -> PreviewFraming {
        var total = PreviewFraming(shift: .zero, scale: 0, rotationRadians: 0)
        var weight: Double = 0
        for (generation, share) in weights.values {
            var framing = pans[generation]?.framing(at: time) ?? .identity
            framing.scale *= gestureScale
            framing.rotationRadians += gestureRotation
            total.shift.x += framing.shift.x * share
            total.shift.y += framing.shift.y * share
            total.scale += framing.scale * share
            total.rotationRadians += framing.rotationRadians * share
            weight += share
        }
        // An ease's weights add up to one; this only keeps rounding off the zoom.
        guard weight > 1e-9 else { return .identity }
        return PreviewFraming(
            shift: CGPoint(x: total.shift.x / weight, y: total.shift.y / weight),
            scale: total.scale / weight, rotationRadians: total.rotationRadians / weight)
    }
}

/// The editor's video frames, taken from the player item one display refresh at a time and handed
/// to the views that show them (`EditorPlayerView`) — the editor's stage and the expansion
/// flight's card.
///
/// The frames don't go to an `AVPlayerLayer`: a player layer's frame reaches the screen on the
/// render server's schedule, off the item's clock, while an ease is a SwiftUI animation committed
/// by the app, and the two land one to four display refreshes apart on an iPhone, differently on
/// every ease (`docs/DESIGN.md` step 6, "Editor preview"). Here the frame due at the next refresh
/// becomes a layer's contents in the same Core Animation transaction as its pan, zoom and turn,
/// and SwiftUI's frame carries an ease's step and the marker's placement, so the whole picture
/// reaches the screen in one commit, on the refresh the frame is due.
///
/// The frames keep the source's colour: an HLG take's stay HLG, and the layer tone maps them for
/// the standard-range display itself, with shadows and midtones about a tenth darker than the
/// player layer showed them (iPhone 13 mini; highlights and colour unchanged). An SDR take looks
/// the same either way.
@MainActor
final class PreviewFrames {
    /// The frames are drawn no larger than this on their long side: past it, the preview can't
    /// show the detail at the editor's zoom range, and the buffers are held in the app.
    nonisolated static let maximumDimension: CGFloat = 1920

    /// The frame shown now, and its presentation time on the item's clock.
    private(set) var latest: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var link: CADisplayLink?
    private var views: [WeakView] = []

    private struct WeakView {
        weak var view: EditorPlayerView.PlayerContainerView?
    }

    /// Takes frames from `item` from now on, as its video composition draws them
    /// (`composition(track:trackID:duration:frameRate:)`).
    func attach(to item: AVPlayerItem) {
        if let output, let attached = self.item {
            attached.remove(output)
        }
        self.item = item
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ])
        item.add(output)
        self.output = output
        latest = nil
    }

    /// The editor item's video composition: each frame turned upright and drawn at its displayed
    /// size, within `maximumDimension`, on the source's own frame times. It never changes with the
    /// framing, so it never has to be swapped on a playing item.
    ///
    /// An HDR track's frames are tone mapped to standard range from iOS 18 (`PreviewCompositor`).
    /// That compositor runs in the app, so its frames count against the app's memory (about 140 MB
    /// for a 1080p HLG take on an iPhone 13 mini, against 48 MB without it); an SDR track, which
    /// looks the same either way, draws through the system's own compositor outside the app.
    nonisolated static func composition(
        track: VideoTrackGeometry, trackID: CMPersistentTrackID, duration: CMTime, frameRate: Double, isHDR: Bool
    ) -> AVVideoComposition {
        let size = track.displayedSize
        let scale = min(1, maximumDimension / max(size.width, size.height, 1))
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate.rounded(), 1)))
        composition.sourceTrackIDForFrameTiming = trackID
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        if #available(iOS 18.0, *), isHDR {
            composition.customVideoCompositorClass = PreviewCompositor.self
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            let transform = PreviewCompositor.transform(track: track, scale: scale)
            composition.instructions = [
                PreviewCompositionInstruction(timeRange: timeRange, trackID: trackID, transform: transform)
            ]
            return composition
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        let layerInstruction = AVMutableVideoCompositionLayerInstruction()
        layerInstruction.trackID = trackID
        layerInstruction.setTransform(
            track.uprightTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        return composition
    }

    func register(_ view: EditorPlayerView.PlayerContainerView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(WeakView(view: view))
        if let latest {
            view.show(latest.buffer, at: latest.time, on: CACurrentMediaTime())
        }
        startLink()
    }

    func unregister(_ view: EditorPlayerView.PlayerContainerView) {
        views.removeAll { $0.view == nil || $0.view === view }
        if views.isEmpty {
            link?.invalidate()
            link = nil
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] link in self?.step(link) },
                                 selector: #selector(DisplayLinkTarget.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Takes the frame due at the refresh this one prepares, if it's new, and shows it.
    private func step(_ link: CADisplayLink) {
        guard let output else { return }
        let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var presentationTime = CMTime.zero
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &presentationTime),
              presentationTime.isNumeric
        else { return }
        latest = (buffer, presentationTime.seconds)
        for entry in views {
            entry.view?.show(buffer, at: presentationTime.seconds, on: link.targetTimestamp)
        }
    }
}

/// A display link's target that runs a closure on each refresh.
@MainActor
final class DisplayLinkTarget: NSObject {
    private let action: (CADisplayLink) -> Void

    init(_ action: @escaping (CADisplayLink) -> Void) {
        self.action = action
    }

    @objc func fire(_ link: CADisplayLink) {
        action(link)
    }
}

/// The editor's video: the frames `PreviewFrames` hands it, each drawn with the framing for its
/// own presentation time (`PreviewPanBlend`) — shifted, zoomed and turned about the clip's crop
/// center — laid out so the unshifted frame sits exactly on the view's bounds. Shared by the
/// editor's stage and the expansion flight's card.
///
/// `animatableData` is the pan's weights, so SwiftUI hands this view each step of an ease, and
/// the view draws it on the frame on screen in the same commit.
struct EditorPlayerView: View, Animatable {
    let frames: PreviewFrames
    /// The source track's geometry, for the encoded frame's size and orientation; `nil` until
    /// media info has loaded.
    let track: VideoTrackGeometry?
    /// The clip's crop center, in displayed pixels: what the picture zooms and turns about.
    let cropCenter: CGPoint
    var pan: PreviewPanBlend
    /// A live pinch and turn, drawn on top of the framing until they commit
    /// (`CropGestureSurface`).
    var gestureScale: CGFloat = 1
    var gestureRotation: Double = 0
    var onReadyForDisplay: (() -> Void)?

    var animatableData: PreviewPanWeights {
        get { pan.weights }
        set { pan.weights = newValue }
    }

    var body: some View {
        Representable(
            frames: frames, track: track,
            drawing: EditorPlayerDrawing(
                pan: pan, cropCenter: cropCenter, gestureScale: gestureScale, gestureRotation: gestureRotation),
            onReadyForDisplay: onReadyForDisplay)
    }

    private struct Representable: UIViewRepresentable {
        let frames: PreviewFrames
        let track: VideoTrackGeometry?
        let drawing: EditorPlayerDrawing
        let onReadyForDisplay: (() -> Void)?

        func makeUIView(context: Context) -> PlayerContainerView {
            let view = PlayerContainerView(frames: frames)
            updateUIView(view, context: context)
            return view
        }

        func updateUIView(_ view: PlayerContainerView, context: Context) {
            view.onReadyForDisplay = onReadyForDisplay
            view.update(track: track, drawing: drawing)
        }
    }

    final class PlayerContainerView: UIView {
        var onReadyForDisplay: (() -> Void)?
        private let frames: PreviewFrames
        private let videoLayer = CALayer()
        private var track: VideoTrackGeometry?
        private var drawing = EditorPlayerDrawing(pan: PreviewPanBlend(pans: [:], weights: .zero), cropCenter: .zero)
        private var frameTime: TimeInterval?
        /// The frame still on screen until the shown one's refresh.
        private var outgoing: OutgoingPreviewFrame?
        /// The frame shown, the one it replaces at its refresh, and the one before, kept until
        /// replaced: the render server may still be drawing an earlier one when the next arrives.
        private var heldBuffers: [CVPixelBuffer] = []
        private var hasShownFrame = false

        init(frames: PreviewFrames) {
            self.frames = frames
            super.init(frame: .zero)
            videoLayer.contentsGravity = .resize
            videoLayer.actions = [
                "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "anchorPoint": NSNull(),
                "transform": NSNull()
            ]
            layer.addSublayer(videoLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                frames.register(self)
            } else {
                frames.unregister(self)
            }
        }

        func update(track: VideoTrackGeometry?, drawing: EditorPlayerDrawing) {
            guard track != self.track || drawing != self.drawing else { return }
            self.track = track
            self.drawing = drawing
            placeVideo()
        }

        /// Shows `buffer`, presented at `time`, with the framing for that time, from the display
        /// refresh at `refresh` on. The layer takes the frame at once and keeps the previous one on
        /// screen until just before that refresh: a frame swapped in as it arrives sometimes
        /// reaches the screen a refresh late, holding one frame and skipping the next (an iPhone 13
        /// mini held and skipped about one 60 fps frame in seven), while one handed over ahead of
        /// its refresh is shown on it.
        func show(_ buffer: CVPixelBuffer, at time: TimeInterval, on refresh: CFTimeInterval) {
            let now = CACurrentMediaTime()
            let handOver = refresh - Self.handOverMargin
            outgoing = videoLayer.contents != nil && handOver - now > Self.handOverMargin
                ? OutgoingPreviewFrame(contents: videoLayer.contents, time: frameTime, until: handOver)
                : nil
            heldBuffers = [buffer] + heldBuffers.prefix(2)
            frameTime = time
            videoLayer.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            placeVideo()
            if !hasShownFrame {
                hasShownFrame = true
                DispatchQueue.main.async { [weak self] in self?.onReadyForDisplay?() }
            }
        }

        /// How far ahead of its refresh a frame takes over from the one before.
        private static let handOverMargin: CFTimeInterval = 0.002

        override func layoutSubviews() {
            super.layoutSubviews()
            placeVideo()
        }

        /// Draws the video layer with the framing for the frame it shows, and the frame still on
        /// screen until the new one's refresh with the framing for its own time, so an ease keeps
        /// moving the picture on every refresh between. Never in a transaction of its own: an
        /// explicit transaction that isn't nested commits on the spot, which can reach the screen a
        /// refresh ahead of what SwiftUI commits for the same frame. The changes ride whatever
        /// transaction is open, SwiftUI's own while it calls `update`, and `actions` keeps them
        /// from animating.
        private func placeVideo() {
            guard let track else { return }
            let placement = placement(for: frameTime, track: track)
            videoLayer.bounds = placement.bounds
            videoLayer.anchorPoint = placement.anchorPoint
            videoLayer.position = placement.position
            videoLayer.setAffineTransform(placement.transform)
            let now = CACurrentMediaTime()
            guard let outgoing, outgoing.until > now else {
                outgoing = nil
                return
            }
            let held = CATransform3DMakeAffineTransform(self.placement(for: outgoing.time, track: track).transform)
            let contents = CABasicAnimation(keyPath: "contents")
            contents.fromValue = outgoing.contents
            contents.toValue = outgoing.contents
            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = NSValue(caTransform3D: held)
            transform.toValue = NSValue(caTransform3D: held)
            let hold = CAAnimationGroup()
            hold.animations = [contents, transform]
            hold.beginTime = videoLayer.convertTime(now, from: nil)
            hold.duration = outgoing.until - now
            videoLayer.add(hold, forKey: "outgoing frame")
        }

        /// Where the frame presented at `time` goes: drawn with the framing a hair past its time,
        /// so a rounding below the frame's own time never draws it with the step before.
        private func placement(for time: TimeInterval?, track: VideoTrackGeometry) -> EditorVideoPlacement {
            let framing = time.map { drawing.framing(at: $0 + 0.0005) } ?? drawing.framing(at: nil)
            return EditorVideoPlacement(
                track: track, bounds: bounds, cropCenter: drawing.cropCenter, framing: framing)
        }
    }
}

/// What `EditorPlayerView` draws its frames with: the blend of framings, the crop center they
/// zoom and turn about, and a live pinch and turn.
struct EditorPlayerDrawing: Equatable {
    var pan: PreviewPanBlend
    var cropCenter: CGPoint
    var gestureScale: CGFloat = 1
    var gestureRotation: Double = 0

    /// The framing for the frame presented at `time`; before any frame, the blend at time zero.
    func framing(at time: TimeInterval?) -> PreviewFraming {
        pan.framing(at: time ?? 0, gestureScale: gestureScale, gestureRotation: gestureRotation)
    }
}

/// Where the editor's video layer goes in its view, and how it is drawn: the upright frame (as the
/// item's composition draws it) the size of the view, so the unshifted frame fills the view's
/// bounds, then shifted by the framing's shift (displayed pixels, at the view's points per
/// displayed pixel) and zoomed and turned about the crop center.
struct EditorVideoPlacement: Equatable {
    let bounds: CGRect
    /// The crop center, as a fraction of the layer's bounds: what the transform turns about.
    let anchorPoint: CGPoint
    /// The crop center in the view.
    let position: CGPoint
    let transform: CGAffineTransform

    init(track: VideoTrackGeometry, bounds viewBounds: CGRect, cropCenter: CGPoint, framing: PreviewFraming) {
        let displayed = track.displayedSize
        let scale = displayed.width > 0 ? viewBounds.width / displayed.width : 0
        bounds = CGRect(origin: .zero, size: viewBounds.size)
        anchorPoint = displayed.width > 0 && displayed.height > 0
            ? CGPoint(x: cropCenter.x / displayed.width, y: cropCenter.y / displayed.height)
            : CGPoint(x: 0.5, y: 0.5)
        position = CGPoint(
            x: viewBounds.minX + anchorPoint.x * viewBounds.width,
            y: viewBounds.minY + anchorPoint.y * viewBounds.height)
        transform = CGAffineTransform(translationX: framing.shift.x * scale, y: framing.shift.y * scale)
            .concatenating(CGAffineTransform(scaleX: framing.scale, y: framing.scale))
            .concatenating(CGAffineTransform(rotationAngle: framing.rotationRadians))
    }
}

/// A preview frame on screen until the next one's refresh (`EditorPlayerView`): its contents, its
/// presentation time, and when it gives way, in `CACurrentMediaTime()`'s timeline.
private struct OutgoingPreviewFrame {
    let contents: Any?
    let time: TimeInterval?
    let until: CFTimeInterval
}
