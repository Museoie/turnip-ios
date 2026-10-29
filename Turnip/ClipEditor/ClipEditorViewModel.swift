import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// How far one press of the editor's crop accessibility actions moves the framing. A gesture
/// supplies a continuous delta; an action has to choose a step. These are coarse enough to
/// reach a corner in a few presses and fine enough to settle on a framing.
enum CropAdjustmentStep {
    static let zoomFactor: CGFloat = 1.25
    static let rotationRadians = Double.pi / 36
    /// A twentieth of the video's own width or height, so a press moves the same fraction of
    /// the picture whatever size the preview is drawn at.
    static let offsetFraction: CGFloat = 0.05
}

/// The crop area's framing at the playhead in words, its accessibility value: what a VoiceOver
/// user's zoom and rotate actions changed, and what a pinch or turn left behind. Each part is
/// measured the way its action steps it — the zoom against the clip's own crop, the turn in
/// whole degrees (`CropAdjustmentStep`).
enum CropAdjustmentDescription {
    static func text(scale: CGFloat, rotationRadians: Double) -> String {
        let zoom = Int((scale * 100).rounded())
        let degrees = Int((rotationRadians * 180 / .pi).rounded())
        let turn: String
        if degrees > 0 {
            turn = String(localized: "turned \(degrees)° clockwise")
        } else if degrees < 0 {
            turn = String(localized: "turned \(-degrees)° counterclockwise")
        } else {
            turn = String(localized: "not turned")
        }
        return String(localized: "Zoom \(zoom)%, \(turn)")
    }
}

/// The clip editor's state (`docs/UIUX.md` § "Clip Detail / Editor").
///
/// Holds the draft trim window, the crop rect the clip opened with, and the follow crop that
/// moves the framing with the athlete over it (Auto follow's keyframes, the user's drags,
/// pinches and turns at the playhead, and Auto rotate's turn); the view commits `result` on
/// back-navigation (the chevron or swipe-to-dismiss) — no separate save step, per the design
/// doc. The crop rect never moves on its own: it is the anchor the marker is laid out from and
/// sets the crop's size. A trim moves no keyframe the user set — a handle drag is a trim, not a
/// re-crop — and re-tracks only a follow crop that is still all Auto follow's. Playback loops
/// the draft window; dragging a handle pauses and seeks to the handle so the preview shows
/// the frame being trimmed to.
///
/// `@MainActor` throughout: the player, its time observer, and the draft state all live on
/// the main thread.
@MainActor
final class ClipEditorViewModel: ObservableObject {
    /// The shortest clip the trim handles can produce. Below this the export would be a
    /// flicker of a few frames; the handles stop instead of crossing.
    nonisolated static let minimumClipDuration: TimeInterval = 0.5

    @Published private(set) var window: TrickWindow
    /// The crop rect the clip opened with — the pipeline's, or the full frame for a clip
    /// added by hand. Fixed for the editor's life: the marker is laid out so this rect
    /// fills it, and every change to the framing is carried by `followCrop`.
    let cropRect: NormalizedRect
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = false

    /// Set when `prepare()` can't load the asset: the view swaps the loading
    /// spinner for an error message instead of spinning forever.
    @Published private(set) var failedToLoad = false
    /// True while Auto rotate is sampling the window's frames for a horizon: the button
    /// shows a spinner and a second tap is ignored until the first detection lands.
    @Published private(set) var isDetectingHorizon = false
    /// Set when Auto rotate found no horizon in the window, so the view can say so — a
    /// button whose tap changes nothing reads as broken. Cleared by the notice itself.
    @Published var isShowingNoHorizonNotice = false
    /// True while the last Auto rotate's turn is what's on screen — "Reset rotate", which
    /// returns the video to its original, unrotated orientation. Cleared by the reset itself
    /// and by any change by hand to the framing, since the fit is then no longer what's on
    /// screen.
    @Published private(set) var isAutoRotateApplied = false

    /// The clip's framing (`docs/UIUX.md` § "Clip Detail / Editor"): the clip's own, or, for one
    /// that opened without one, `nil` until media info has loaded and Auto follow's (or the whole
    /// frame's) is worked out. The preview draws it frame by frame through `followPan`.
    @Published private(set) var followCrop: FollowCrop? {
        didSet { rebuildFollowPan() }
    }
    /// The follow crop's center, zoom and turn, one step per source frame, for the preview to play.
    @Published private(set) var followPan: FollowPan? {
        didSet { updatePreviewPan() }
    }
    /// What the preview draws the picture with: the pan it draws now under the current generation
    /// (none before the follow crop is in hand), and the weights of every generation still on
    /// screen. An ease (`easePan(_:)`) gives the new pan a new generation and animates the
    /// weights onto it; any other change replaces the current generation's pan.
    @Published private(set) var previewPan = PreviewPanBlend(pans: [:], weights: PreviewPanWeights([0: 1]))
    private var previewGeneration = 0
    /// When each earlier generation was eased away from: its pan is kept until no ease can still
    /// be drawing it.
    private var supersededPreviewGenerations: [Int: CFTimeInterval] = [:]
    /// The editor's frames, for the views that show them.
    let previewFrames = PreviewFrames()
    /// The editor item's composition (`PreviewFrames.composition`), once the track is read.
    private var previewComposition: AVVideoComposition?
    /// Set when Auto follow found nothing that moves, so the view can say why the crop holds
    /// still. Cleared by the notice itself.
    @Published var isShowingNothingToFollowNotice = false

    /// A keyframe's zoom is clamped here, and the automatic fits' zoom too, so neither can
    /// shrink the video to a sliver or blow it up past usefulness.
    nonisolated static let scaleRange: ClosedRange<CGFloat> = 0.2...8

    /// How Auto follow, Reset follow and Auto rotate move the video to their result: along the
    /// same position, zoom and turn the fingers drive, over this curve, so the user sees what
    /// changed and from where (`docs/UIUX.md` § "An automatic change moves, it never cuts").
    nonisolated static let fitAnimation: Animation = .easeInOut(duration: fitDuration)
    nonisolated static let fitDuration: TimeInterval = 0.4

    /// The player the view renders. Created up front so `ClipEditorVideoSurface` (the
    /// editor's stage and a presenter's flying card) always has a player to render; the
    /// item is attached in `prepare()` or `holdPlayback(at:)`.
    let player = AVPlayer()

    /// What Auto rotate levels by: `ClipLeveler` in the app (the take's roll track, else the
    /// picture's horizon), a canned answer in tests.
    typealias LevelingRotation = @Sendable (AVAsset, TrickWindow) async throws -> Double?

    private let source: ClipEditorSource
    private let calculator: CropRectCalculator
    private let autoFollower: AutoFollow
    /// Auto follow's crop for the window the editor opened with, when the clip opened without one
    /// of its own. Still that crop at the close, the clip goes back without one.
    private var openingFollowCrop: FollowCrop?
    private var nominalFrameRate: Double = 30
    /// The source's real frame times around the window, once read.
    private var frameTimes: VideoFrameTimes?
    private var frameTimesTask: Task<Void, Never>?
    private let levelingRotation: LevelingRotation
    private var timeObserver: Any?
    /// The item's end-of-playback observer: a window ending at the asset's end plays the
    /// item out, which pauses the player on its own (`AVPlayer`'s default
    /// `actionAtItemEnd`), and the periodic tick's loop-back seek alone would land on a
    /// paused player — the preview would stop at the end of the clip instead of looping.
    private var didPlayToEndObserver: NSObjectProtocol?
    /// The source track's encoded size and orientation, once media info has loaded.
    private(set) var trackGeometry: VideoTrackGeometry?
    private var videoTrackID: CMPersistentTrackID?
    private var assetDuration: CMTime?
    /// The in-flight Auto rotate detection, kept so `teardown()` can cancel it: the
    /// decode outlives a closed editor otherwise.
    private var horizonTask: Task<Void, Never>?

    /// True while a handle drag is in flight. The drag's programmatic seek lands exactly on
    /// the moved handle, and without this guard the periodic time observer would read that
    /// jump as the loop point and bounce the preview back to the window start.
    ///
    /// Set by `trimStart`/`trimEnd` and normally cleared by `finishTrim`, but `onEnded`
    /// doesn't fire when a gesture is cancelled (e.g. a system gesture takeover mid-drag),
    /// so the latch is also cleared defensively whenever the preview loop is (re)armed
    /// (`prepare`/`startPreview`) or the view goes away (`teardown`): a stranded `true`
    /// would pause playback forever and let the preview run past the end handle.
    ///
    /// `private(set)` rather than `private` so tests can assert the latch transitions
    /// (`trimEnd` sets it, `finishTrim` clears it).
    private(set) var isTrimming = false
    private let mayAutoplayLoops: @MainActor () -> Bool

    /// `false` while a presenter is holding playback for its opening flight — see
    /// `holdPlayback(at:)`. `prepare()` then arms the player without seeking or
    /// playing, and `releasePlayback()` starts the loop once the flight has landed.
    private var isPlaybackReleased = true
    /// True while a presenter is scrubbing the player for an expansion flight. The
    /// periodic observer's loop-back is suppressed meanwhile, the same way it is for a
    /// handle drag: a scrub landing near the window's end would otherwise bounce back
    /// to the start the moment it got there.
    private var isPresenterScrubbing = false

    init(
        source: ClipEditorSource,
        calculator: CropRectCalculator = CropRectCalculator(),
        levelingRotation: @escaping LevelingRotation = { try await ClipLeveler.levelingRotation(in: $0, window: $1) },
        mayAutoplayLoops: @escaping @MainActor () -> Bool = {
            mayAutoplayVideoLoops(
                isVideoAutoplayEnabled: UIAccessibility.isVideoAutoplayEnabled,
                isReduceMotionEnabled: UIAccessibility.isReduceMotionEnabled)
        }
    ) {
        self.source = source
        self.calculator = calculator
        self.levelingRotation = levelingRotation
        self.mayAutoplayLoops = mayAutoplayLoops
        self.autoFollower = AutoFollow(
            pathCalculator: CropPathCalculator(rectCalculator: calculator),
            aspectRatio: CGFloat(calculator.targetAspectRatio))
        self.window = source.window
        self.cropRect = source.cropRect
        self.followCrop = source.followCrop
    }

    /// The committed edits, in the shape the clip list applies to its item.
    ///
    /// A clip that opened without a follow crop goes back without one only while both the crop
    /// and the window are as it opened: the Clip List works an unset crop out for the clip's
    /// window, zoom included, and a trimmed window would get a new zoom there.
    var result: ClipEditorResult {
        let openedWindow = duration.map { Self.clamped(window: source.window, to: $0) } ?? source.window
        let isAsOpened = openingFollowCrop != nil && followCrop == openingFollowCrop && window == openedWindow
        return ClipEditorResult(window: window, cropRect: cropRect, followCrop: isAsOpened ? nil : followCrop)
    }

    /// "2.4s"-style duration of the draft window, via the one shared clip-duration
    /// formatter — the same window must read the same in the editor and on the clip
    /// list's tile.
    var durationLabel: String {
        ClipDurationFormatter.string(from: window.endTime - window.startTime)
    }

    /// The timeline's visible range: the whole source video, so its position always
    /// reads as "roughly this part of the video," matching the clip list's tiles
    /// (`docs/UIUX.md` § "Clip Detail / Editor"). This trades away handle precision on
    /// a long video — `TrimSliderView`'s vertical drag-to-slow gesture is the mitigation.
    /// Nil until the duration loads.
    var visibleRange: ClosedRange<TimeInterval>? {
        guard let duration, duration > 0 else { return nil }
        return 0...duration
    }

    /// The crop marker's aspect ratio (width over height): the calculator's own target, which
    /// every rect it produces has in pixels — so the fixed marker is exactly the crop rect's
    /// shape and the video maps onto it by one uniform scale (`ClipEditorStage`).
    var targetAspectRatio: CGFloat {
        CGFloat(calculator.targetAspectRatio)
    }

    /// The crop area's accessibility value (`CropAdjustmentDescription`): the follow crop's zoom
    /// and turn at the playhead, or none before the clip has one.
    var cropAdjustmentDescription: String {
        let framing = followCrop?.path.framing(at: playbackTime)
        return CropAdjustmentDescription.text(
            scale: framing?.scale ?? 1, rotationRadians: framing?.rotationRadians ?? 0)
    }

    /// The stage geometry in one value: the displayed (upright) frame size plus the crop
    /// rect mapped into that space. Nil until media info loads; the view lays the video out
    /// under the fixed marker from it.
    var previewOverlay: (videoSize: CGSize, cropRect: CGRect)? {
        guard let trackGeometry, let crop = trackGeometry.displayedCropRect(cropRect) else { return nil }
        return (videoSize: trackGeometry.displayedSize, cropRect: crop)
    }

    /// Loads the asset's duration and frame geometry, then starts the preview loop. Called
    /// from the view's `.task`; safe to call again — re-appearing re-arms the loop.
    func prepare() async {
        // A cancelled drag never clears the latch (its `onEnded` doesn't fire), so reset
        // it here: `prepare()` always re-arms the loop on success, and the loop must
        // resume loop-back behavior rather than inheriting a stale suppression.
        isTrimming = false
        guard let tracks = try? await source.asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let assetDuration = try? await source.asset.load(.duration),
              assetDuration.isValid,
              let naturalSize = try? await track.load(.naturalSize),
              naturalSize.width > 0, naturalSize.height > 0,
              let preferredTransform = try? await track.load(.preferredTransform)
        else {
            failedToLoad = true
            return
        }
        let frameRate = (try? await track.load(.nominalFrameRate)).map(Double.init) ?? 0
        videoTrackID = track.trackID
        self.assetDuration = assetDuration
        setMediaInfo(
            duration: assetDuration.seconds,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            frameRate: frameRate > 0 ? frameRate : 30)
        if previewComposition == nil {
            let characteristics = (try? await track.load(.mediaCharacteristics)) ?? []
            previewComposition = PreviewFrames.composition(
                track: VideoTrackGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform),
                trackID: track.trackID, duration: assetDuration, frameRate: frameRate > 0 ? frameRate : 30,
                isHDR: characteristics.contains(.containsHDRVideo))
        }
        // The frames come upright only through the composition.
        if let item = player.currentItem, item.videoComposition == nil {
            item.videoComposition = previewComposition
        }
        if isPlaybackReleased {
            startPreview()
        } else {
            armPlayer()
        }
    }

    /// The frame the player is currently showing, in asset time.
    var currentTime: TimeInterval {
        let time = player.currentTime()
        return time.isNumeric ? time.seconds : window.startTime
    }

    /// Holds the preview loop back for a presenter's opening flight: attaches the player
    /// item if needed, pauses, and seeks exactly to `time` — the frame the flight starts
    /// on — without starting the loop. `prepare()` running afterwards leaves playback held
    /// too; `releasePlayback()` is what starts it. Returns once the seek has completed, so
    /// the caller knows the player can show that frame.
    func holdPlayback(at time: TimeInterval) async {
        isPlaybackReleased = false
        isPresenterScrubbing = true
        if player.currentItem == nil, previewComposition == nil {
            previewComposition = await loadPreviewComposition()
        }
        armPlayer()
        player.pause()
        await scrub(to: time)
    }

    /// The editor item's composition, read from the asset's video track ahead of `prepare()` for
    /// a presenter's opening flight; `nil` if the track can't be read.
    private func loadPreviewComposition() async -> AVVideoComposition? {
        guard let track = try? await source.asset.loadTracks(withMediaType: .video).first,
              let duration = try? await source.asset.load(.duration), duration.isValid,
              let (naturalSize, transform, frameRate, characteristics) = try? await track.load(
                  .naturalSize, .preferredTransform, .nominalFrameRate, .mediaCharacteristics),
              naturalSize.width > 0, naturalSize.height > 0
        else { return nil }
        return PreviewFrames.composition(
            track: VideoTrackGeometry(naturalSize: naturalSize, preferredTransform: transform),
            trackID: track.trackID, duration: duration, frameRate: frameRate > 0 ? Double(frameRate) : 30,
            isHDR: characteristics.contains(.containsHDRVideo))
    }

    /// Ends `holdPlayback(at:)`'s hold: starts the preview loop from the window's start if
    /// media info has loaded, or lets `prepare()` start it when it does.
    func releasePlayback() {
        isPlaybackReleased = true
        isPresenterScrubbing = false
        if duration != nil {
            startPreview()
        }
    }

    /// Pauses the preview for a presenter's closing flight or interactive dismiss, keeping
    /// `isPlaying` (the user's intent) as it was, and returns the frame the scrub starts
    /// from. Safe to call again mid-scrub: it just reports the current frame.
    func beginPresenterScrub() -> TimeInterval {
        isPresenterScrubbing = true
        player.pause()
        return currentTime
    }

    /// Ends a presenter scrub that didn't close the editor after all (a cancelled
    /// dismiss drag): resumes playback if the user hadn't paused it.
    func endPresenterScrub() {
        isPresenterScrubbing = false
        if isPlaying {
            player.play()
        }
    }

    /// Seeks exactly to `time` and returns once the player has that frame.
    func scrub(to time: TimeInterval) async {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTime = time
    }

    /// Stops playback and drops the time observer. Called when the view disappears.
    /// Also clears the trim latch: if the disappearing view was mid-drag, the gesture's
    /// `onEnded` never fired, and re-appearing must re-arm a clean loop via `prepare()`.
    func teardown() {
        isTrimming = false
        horizonTask?.cancel()
        horizonTask = nil
        isDetectingHorizon = false
        frameTimesTask?.cancel()
        frameTimesTask = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
            self.didPlayToEndObserver = nil
        }
        player.pause()
    }

    /// Zooms the playhead's keyframe by `delta` (`setFollowKeyframe`): VoiceOver's Zoom in and
    /// Zoom out, which step what a pinch does.
    func applyCropScale(_ delta: CGFloat) {
        guard delta.isFinite, delta > 0, delta != 1 else { return }
        setFollowKeyframe(zoomedBy: delta)
    }

    /// Turns the playhead's keyframe by `deltaRadians` (`setFollowKeyframe`): VoiceOver's Rotate
    /// clockwise and Rotate counterclockwise, which step what a two-finger turn does.
    func applyCropRotation(_ deltaRadians: Double) {
        guard deltaRadians.isFinite, deltaRadians != 0 else { return }
        setFollowKeyframe(turnedBy: deltaRadians)
    }

    /// A change by hand to the framing takes it over from Auto rotate: its turn is no longer
    /// what's on screen, so the button returns to offering the fit. Called only for a change
    /// that actually changed something — a pinch that ends where it started is not an edit.
    /// Auto follow's own button reads the follow crop (`isAutoFollowApplied`).
    private func clearAutoRotate() {
        isAutoRotateApplied = false
    }

    /// "Reset rotate": returns the video to its original, unrotated orientation, moving
    /// there the same way the turn moved. Positions and zoom stay. The button then offers
    /// Auto rotate again.
    func resetRotate() {
        guard isAutoRotateApplied else { return }
        isAutoRotateApplied = false
        withAnimation(Self.fitAnimation) {
            easePan { setRotation(0) }
        }
    }

    /// Turns every keyframe of the follow crop (`FollowCrop.setRotation`).
    private func setRotation(_ radians: Double) {
        guard var followCrop else { return }
        followCrop.setRotation(radians)
        self.followCrop = followCrop
    }

    /// The adjustment that frames `normalizedKeypoints` in the marker at `rotationRadians`,
    /// or `nil` when there is nothing to frame: Auto follow's one keyframe for an athlete who
    /// stays put (`AutoFollow`). Pure, so the fit is unit-testable without a player; the rotated
    /// case is the discriminating one.
    ///
    /// The marker shows the video turned by the rotation about the crop rect's center, so
    /// the fit runs in that turned space: each keypoint is rotated about the center, the
    /// same calculator that produced the pipeline's rects frames the rotated set (minus
    /// its slide back into the frame — `containedInFrame` does that, for any rotation),
    /// the rect is moved and if need be shrunk to lie inside the video, and the result is
    /// expressed as what scale and offset land it on the marker: the marker spans
    /// `markerBox` in displayed pixels, so the scale is the two widths' ratio, and the
    /// offset moves the rect's center onto the marker's in screen space, after the scale.
    nonisolated static func autoCropAdjustment(
        normalizedKeypoints: [CGPoint],
        cropRect: CGRect,
        videoSize: CGSize,
        rotationRadians: Double,
        calculator: CropRectCalculator
    ) -> CropAdjustment? {
        guard !normalizedKeypoints.isEmpty, cropRect.width > 0, cropRect.height > 0 else { return nil }
        let marker = markerBox(around: cropRect, aspectRatio: CGFloat(calculator.targetAspectRatio))
        let center = CGPoint(x: cropRect.midX, y: cropRect.midY)
        let rotation = CGAffineTransform(rotationAngle: rotationRadians)
        let turnedKeypoints = normalizedKeypoints.map { point -> CGPoint in
            let turned = CGPoint(
                x: point.x * videoSize.width - center.x,
                y: point.y * videoSize.height - center.y
            ).applying(rotation)
            return CGPoint(
                x: (turned.x + center.x) / videoSize.width,
                y: (turned.y + center.y) / videoSize.height)
        }
        guard let fit = calculator.cropRect(
                  around: turnedKeypoints, renderedPixelSize: videoSize, slidIntoFrame: false)?
                  .denormalized(in: videoSize),
              fit.width > 0, fit.height > 0
        else { return nil }
        let contained = containedInFrame(
            fit.offsetBy(dx: -center.x, dy: -center.y),
            frameSize: videoSize, cropCenter: center, rotationRadians: rotationRadians)
        let scale = clampedScale(marker.width / contained.width)
        return CropAdjustment(
            scale: scale,
            rotationRadians: rotationRadians,
            offset: CGSize(width: -contained.midX * scale, height: -contained.midY * scale))
    }

    /// `box` — an axis-aligned rect in the turned space, relative to the crop center —
    /// moved, and if it has to be shrunk at its own aspect ratio, so that it lies inside
    /// the video: the crop then shows video in every part of it, never the black beyond
    /// the frame's edge. In the turned space the frame is its own rect turned by the
    /// rotation about the crop center, so "inside" is measured along the frame's own two
    /// axes: the box's extent along the frame's width axis is `|cos| · w + |sin| · h`
    /// (and `|sin| · w + |cos| · h` along its height), it fits when both are no more than
    /// the frame's, and its center may then sit anywhere within the slack that leaves —
    /// a rect in the frame's axes, so the nearest allowed center is the box's own center
    /// clamped axis by axis. A box too big to fit is shrunk to the widest that does and
    /// centered where the slack is zero; the keypoints it was fitted to may then fall
    /// outside it, since no crop of this ratio can hold them all and stay inside the video.
    /// At zero rotation this is the calculator's own slide back into the frame, except
    /// that an axis longer than the frame shrinks to it rather than overhanging it.
    nonisolated static func containedInFrame(
        _ box: CGRect, frameSize: CGSize, cropCenter: CGPoint, rotationRadians: Double
    ) -> CGRect {
        guard box.width > 0, box.height > 0, frameSize.width > 0, frameSize.height > 0 else { return box }
        let cosine = cos(rotationRadians), sine = sin(rotationRadians)
        let ratio = box.width / box.height
        let widestFitting = min(
            frameSize.width / (abs(cosine) + abs(sine) / ratio),
            frameSize.height / (abs(sine) + abs(cosine) / ratio))
        let width = min(box.width, widestFitting), height = width / ratio
        let slackAlongWidth = max(0, (frameSize.width - (abs(cosine) * width + abs(sine) * height)) / 2)
        let slackAlongHeight = max(0, (frameSize.height - (abs(sine) * width + abs(cosine) * height)) / 2)
        // The frame's center and axes in the turned space.
        let frameCenter = CGPoint(
            x: frameSize.width / 2 - cropCenter.x, y: frameSize.height / 2 - cropCenter.y
        ).applying(CGAffineTransform(rotationAngle: rotationRadians))
        let widthAxis = CGPoint(x: cosine, y: sine), heightAxis = CGPoint(x: -sine, y: cosine)
        let delta = CGPoint(x: box.midX - frameCenter.x, y: box.midY - frameCenter.y)
        let alongWidth = min(max(delta.x * widthAxis.x + delta.y * widthAxis.y, -slackAlongWidth), slackAlongWidth)
        let alongHeight = min(max(delta.x * heightAxis.x + delta.y * heightAxis.y, -slackAlongHeight), slackAlongHeight)
        let center = CGPoint(
            x: frameCenter.x + alongWidth * widthAxis.x + alongHeight * heightAxis.x,
            y: frameCenter.y + alongWidth * widthAxis.y + alongHeight * heightAxis.y)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// The crop marker's extent in displayed pixels: the smallest rect of `aspectRatio`
    /// (width over height) around `cropRect`, centered on it — what `ClipEditorStage`'s
    /// placement maps onto the marker. Exactly `cropRect` when the rect already has the
    /// marker's ratio, which every pipeline rect does; wider or taller for a full-frame
    /// rect, which a clip added by hand opens with.
    nonisolated static func markerBox(around cropRect: CGRect, aspectRatio: CGFloat) -> CGRect {
        guard aspectRatio > 0 else { return cropRect }
        let size = cropRect.width / cropRect.height < aspectRatio
            ? CGSize(width: cropRect.height * aspectRatio, height: cropRect.height)
            : CGSize(width: cropRect.width, height: cropRect.width / aspectRatio)
        return CGRect(
            x: cropRect.midX - size.width / 2, y: cropRect.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    /// The "Auto rotate" action: levels the clip by the take's own roll track when it has
    /// one, else by the horizon read off frames sampled across the draft window
    /// (`ClipLeveler`). Replaces the rotation rather than adding to it — the roll is
    /// measured on the source, not on the rotated preview. Positions and zoom stay as they
    /// are; Auto follow refits them if the turn carries a limb out of the marker. One
    /// detection at a time: a tap while one is running is ignored, and `teardown()` cancels
    /// it. Finding nothing to level by raises the notice and changes nothing; finding a
    /// rotation turns the video to level over `fitAnimation` rather than cutting to it, and
    /// the button becomes "Reset rotate".
    func autoRotate() {
        guard !isDetectingHorizon, duration != nil else { return }
        isDetectingHorizon = true
        let asset = source.asset
        let window = window
        let levelingRotation = levelingRotation
        horizonTask = Task { [weak self] in
            let rotation = try? await levelingRotation(asset, window)
            guard let self, !Task.isCancelled else { return }
            isDetectingHorizon = false
            if let rotation {
                withAnimation(Self.fitAnimation) {
                    easePan { setRotation(rotation) }
                }
                isAutoRotateApplied = true
            } else {
                // Inside a transaction so the notice's slide-and-fade transition plays.
                withAnimation(Self.fitAnimation) {
                    isShowingNoHorizonNotice = true
                }
            }
        }
    }

    // MARK: - Follow mode

    /// Whether Auto follow has anything to fit: the clip came with pose analysis. A clip of a
    /// video that skipped analysis ("Clip manually") never does, so it gets Reset follow alone —
    /// an Auto follow whose tap could never change anything reads as broken.
    var supportsAutoFollow: Bool {
        !source.poseFrames.isEmpty
    }

    /// True while the follow crop on screen is exactly what Auto follow wrote, which turns its
    /// button into Reset follow.
    var isAutoFollowApplied: Bool {
        followCrop?.isAutoFollow == true
    }

    /// Whether the follow crop shows anything but Reset follow's whole frame — a keyframe or a
    /// resting framing at another position or zoom — which a turn alone doesn't count as: what
    /// enables a clip without pose analysis's Reset follow.
    var isFollowAdjusted: Bool {
        guard let followCrop, let overlay = previewOverlay else { return false }
        let whole = FollowCrop.wholeFrame(
            cropRect: overlay.cropRect, videoSize: overlay.videoSize, rotationRadians: 0,
            aspectRatio: targetAspectRatio).resting
        func differs(_ framing: FollowFraming) -> Bool {
            abs(framing.scale - whole.scale) > 1e-6 * whole.scale
                || hypot(framing.center.x - whole.center.x, framing.center.y - whole.center.y) > 1e-6
        }
        return differs(followCrop.resting) || followCrop.keyframes.contains { differs($0.framing) }
    }

    /// "Auto follow": frames the athlete through the window at the turn the crop has at the
    /// playhead — the pipeline's follow path reduced to a few keyframes (`AutoFollow`), each
    /// zoomed to the room the athlete needs around then. Keeps the turn and replaces the zoom
    /// and every keyframe, the user's too. The picture moves to the new path at the playhead over
    /// `fitAnimation` and then follows it. A path that never moves frames the athlete with
    /// one keyframe and raises "Nothing to follow"; a window with nothing located changes
    /// nothing but the notice.
    func autoFollow() {
        guard supportsAutoFollow, let overlay = previewOverlay else { return }
        let rotation = followRotationAtPlayhead
        guard let fit = autoFollower.fit(
            frames: framesInWindow, cropRect: overlay.cropRect, videoSize: overlay.videoSize,
            rotationRadians: rotation)
        else {
            withAnimation(Self.fitAnimation) { isShowingNothingToFollowNotice = true }
            return
        }
        withAnimation(Self.fitAnimation) {
            easePan { followCrop = fit.crop }
        }
        if !fit.moves {
            withAnimation(Self.fitAnimation) { isShowingNothingToFollowNotice = true }
        }
    }

    /// "Reset follow": the whole source frame centered in the marker with no keyframes, so the
    /// crop holds still, at the current turn. Moves there the way Auto follow moves.
    func resetFollow() {
        guard let overlay = previewOverlay,
              isAutoFollowApplied || isFollowAdjusted
        else { return }
        let rotation = followRotationAtPlayhead
        withAnimation(Self.fitAnimation) {
            easePan {
                followCrop = FollowCrop.wholeFrame(
                    cropRect: overlay.cropRect, videoSize: overlay.videoSize, rotationRadians: rotation,
                    aspectRatio: targetAspectRatio)
            }
        }
    }

    /// The follow crop's turn at the playhead, or none before the clip has one: the one turn
    /// Auto follow and Reset follow keep.
    private var followRotationAtPlayhead: Double {
        followCrop?.path.framing(at: currentTime).rotationRadians ?? 0
    }

    /// Makes the pan change `change` makes ease in from where the picture is instead of cutting
    /// to it: the pan drawn now keeps its generation, the changed one gets a new one, and the
    /// weights move onto it along the transaction's animation. Called inside a
    /// `withAnimation(Self.fitAnimation)`, so SwiftUI steps the ease of the pan, the zoom and the
    /// turn together (`PreviewPanWeights`).
    private func easePan(_ change: () -> Void) {
        let from = previewGeneration
        previewGeneration += 1
        previewPan.pans[previewGeneration] = previewPan.pans[from]
        change()
        guard previewPan.pans[previewGeneration] != previewPan.pans[from] else {
            previewPan.pans[previewGeneration] = nil
            previewGeneration = from
            return
        }
        let now = CACurrentMediaTime()
        supersededPreviewGenerations[from] = now
        for (generation, time) in supersededPreviewGenerations where now - time > Self.fitDuration + 1 {
            previewPan.pans[generation] = nil
            supersededPreviewGenerations[generation] = nil
        }
        previewPan.weights = PreviewPanWeights([previewGeneration: 1])
    }

    /// Puts the pan the preview should draw now on the current generation: a change that doesn't
    /// ease of its own cuts to it, or, mid-ease, becomes what the ease is heading for.
    private func updatePreviewPan() {
        guard previewPan.pans[previewGeneration] != followPan else { return }
        previewPan.pans[previewGeneration] = followPan
    }

    /// The follow crop's keyframes, for the lane: in time order.
    var followKeyframes: [FollowKeyframe] {
        followCrop?.keyframes ?? []
    }

    /// The follow lane's scrub: pauses playback — the clip stays where the lane left it until
    /// Play — and seeks exactly to `time`, kept inside the window. The periodic tick's loop-back
    /// stays off while paused, so a scrub to the window's end doesn't bounce to its start.
    func scrubFollowLane(to time: TimeInterval) {
        guard duration != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        seek(to: min(max(time, window.startTime), window.endTime))
    }

    // MARK: - Keyframes by hand

    /// How near the playhead a keyframe has to be for a drag, the lane's button or Remove
    /// keyframe to act on it rather than add one.
    nonisolated static let keyframeReach: TimeInterval = 0.1

    /// The keyframe within `keyframeReach` of the playhead, the nearest one if several are.
    var keyframeAtPlayhead: FollowKeyframe? {
        let time = currentTime
        return followKeyframes
            .filter { abs($0.time - time) <= Self.keyframeReach }
            .min { abs($0.time - time) < abs($1.time - time) }
    }

    /// Touch-down on the crop area: the gesture sets the framing at this moment, so the
    /// clip stops here and stays stopped on release, until Play.
    func beginFollowTouch() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    /// One gesture on the crop area, committed as the fingers lift: its drag's `translation` (in
    /// on-screen points, at `previewScale` points per displayed pixel —
    /// `ClipEditorStage.VideoPlacement.pointsPerDisplayedPixel`), its pinch's `scale` and its
    /// turn's `rotation`, all written into the playhead's keyframe at once (`setFollowKeyframe`).
    func applyFollowGesture(translation: CGSize, previewScale: CGFloat, scale: CGFloat, rotation: Double) {
        guard previewScale.isFinite, previewScale > 0 else { return }
        setFollowKeyframe(
            movedBy: CGSize(width: translation.width / previewScale, height: translation.height / previewScale),
            zoomedBy: scale, turnedBy: rotation)
    }

    /// Places the video at the playhead's moment, `delta` further across the screen in
    /// displayed pixels — what VoiceOver's moves step (`setFollowKeyframe`).
    func moveFollow(byDisplayedPixels delta: CGSize) {
        setFollowKeyframe(movedBy: delta)
    }

    /// Sets the framing at the playhead's moment: the video `delta` further across the screen (in
    /// displayed pixels, after the zoom and turn), zoomed by `factor` and turned by `radians`
    /// more. A drag, a pinch and a turn all write it, and one two-finger gesture writes all three
    /// at once. Within `keyframeReach` of a keyframe it changes that keyframe; anywhere else it
    /// adds one that starts from where the curves already are, so the picture at the playhead is
    /// exactly where the fingers left it. The zoom stays within `scaleRange`. Any keyframe change
    /// hands Auto follow's button back.
    func setFollowKeyframe(movedBy delta: CGSize = .zero, zoomedBy factor: CGFloat = 1, turnedBy radians: Double = 0) {
        guard var crop = followCrop,
              delta.width.isFinite, delta.height.isFinite, factor.isFinite, factor > 0, radians.isFinite,
              delta != .zero || factor != 1 || radians != 0
        else { return }
        let time = currentTime
        let index: Int
        if let nearest = keyframeAtPlayhead, let found = crop.keyframes.firstIndex(of: nearest) {
            index = found
        } else {
            crop.keyframes.append(FollowKeyframe(time: time, framing: crop.path.framing(at: time)))
            crop.keyframes.sort { $0.time < $1.time }
            index = crop.keyframes.lastIndex { $0.time == time } ?? crop.keyframes.count - 1
        }
        var keyframe = crop.keyframes[index]
        keyframe.scale = Self.clampedScale(keyframe.scale * factor)
        keyframe.rotationRadians += radians
        // The video moved `delta` on screen, after the new zoom and turn: the source point at
        // the marker's center moved the other way by that much undone.
        let unturned = CGPoint(x: delta.width, y: delta.height)
            .applying(CGAffineTransform(rotationAngle: -keyframe.rotationRadians))
        keyframe.center.x -= unturned.x / keyframe.scale
        keyframe.center.y -= unturned.y / keyframe.scale
        crop.keyframes[index] = keyframe
        crop.isAutoFollow = false
        clearAutoRotate()
        followCrop = crop
    }

    /// "Apply zoom and turn to all keyframes": every keyframe takes `keyframe`'s zoom and turn and
    /// keeps its own position, the one way to make the whole clip tighter, wider or more level at
    /// once. It is the user's change, so every keyframe it changes fills in, and the picture
    /// moves there over `fitAnimation`.
    func applyZoomAndTurnToAllKeyframes(from keyframe: FollowKeyframe) {
        applyZoomAndTurnToAllKeyframes(scale: keyframe.scale, rotationRadians: keyframe.rotationRadians)
    }

    /// The crop area's VoiceOver "Apply zoom and turn to all keyframes": the zoom and turn at the
    /// playhead.
    func applyZoomAndTurnAtPlayheadToAllKeyframes() {
        guard let framing = followCrop?.path.framing(at: currentTime) else { return }
        applyZoomAndTurnToAllKeyframes(scale: framing.scale, rotationRadians: framing.rotationRadians)
    }

    private func applyZoomAndTurnToAllKeyframes(scale: CGFloat, rotationRadians: Double) {
        guard var crop = followCrop, !crop.keyframes.isEmpty else { return }
        for index in crop.keyframes.indices {
            crop.keyframes[index].scale = scale
            crop.keyframes[index].rotationRadians = rotationRadians
        }
        guard crop != followCrop else { return }
        crop.isAutoFollow = false
        clearAutoRotate()
        withAnimation(Self.fitAnimation) {
            easePan { followCrop = crop }
        }
    }

    /// The lane's trailing button: adds a keyframe at the playhead where the curves already are
    /// — the picture doesn't move — or, with one within `keyframeReach`, removes that one.
    func toggleKeyframeAtPlayhead() {
        if let keyframe = keyframeAtPlayhead {
            removeKeyframe(keyframe)
        } else {
            addKeyframeAtPlayhead()
        }
    }

    func addKeyframeAtPlayhead() {
        guard var crop = followCrop, keyframeAtPlayhead == nil else { return }
        let time = currentTime
        crop.keyframes.append(FollowKeyframe(time: time, framing: crop.path.framing(at: time)))
        crop.keyframes.sort { $0.time < $1.time }
        crop.isAutoFollow = false
        clearAutoRotate()
        followCrop = crop
    }

    /// Removes `keyframe`: one Auto follow wrote and the user changed goes back to Auto follow's
    /// position, zoom and turn, hollow again; any other is deleted. The picture moves to the new
    /// curve the way an automatic change does, since the curve at the playhead can change.
    func removeKeyframe(_ keyframe: FollowKeyframe) {
        guard var crop = followCrop,
              let index = crop.keyframes.firstIndex(of: keyframe)
        else { return }
        if let auto = keyframe.autoFraming, auto != keyframe.framing {
            crop.keyframes[index].framing = auto
        } else {
            crop.keyframes.remove(at: index)
        }
        crop.isAutoFollow = false
        clearAutoRotate()
        withAnimation(Self.fitAnimation) {
            easePan { followCrop = crop }
        }
    }

    /// VoiceOver's Previous keyframe and Next keyframe: the playhead jumps to the nearest
    /// keyframe before or after it, pausing, as a tap on its diamond does.
    func seekToKeyframe(after: Bool) {
        let time = currentTime
        let inWindow = followKeyframes.filter { $0.time >= window.startTime && $0.time <= window.endTime }
        let target = after
            ? inWindow.first { $0.time > time + 0.001 }
            : inWindow.last { $0.time < time - 0.001 }
        guard let target else { return }
        scrubFollowLane(to: target.time)
    }

    /// Rebuilds the preview's pan from the follow crop and the source's frame times, reading
    /// the real times for the span the crop moves over when they aren't in hand yet; until
    /// then the frames are on the track's nominal grid.
    private func rebuildFollowPan() {
        guard let followCrop, let overlay = previewOverlay else {
            followPan = nil
            return
        }
        let cropCenter = CGPoint(x: overlay.cropRect.midX, y: overlay.cropRect.midY)
        guard let span = followCrop.path.movingSpan else {
            followPan = FollowPan(crop: followCrop, cropCenter: cropCenter, frames: [])
            return
        }
        let frames = frameTimes?.frames(across: span)
            ?? VideoFrameTimes.nominalFrames(across: span, frameRate: nominalFrameRate)
        followPan = FollowPan(crop: followCrop, cropCenter: cropCenter, frames: frames)
        if frameTimes?.frames(across: span) == nil {
            loadFrameTimes(covering: span)
        }
    }

    private func loadFrameTimes(covering span: ClosedRange<TimeInterval>) {
        guard frameTimesTask == nil else { return }
        let lower = min(span.lowerBound, window.startTime) - 1
        let upper = max(span.upperBound, window.endTime) + 1
        let asset = source.asset
        frameTimesTask = Task { [weak self] in
            let times = await VideoFrameTimes.load(from: asset, over: lower...upper)
            guard let self, !Task.isCancelled else { return }
            frameTimesTask = nil
            guard let times else { return }
            frameTimes = times
            rebuildFollowPan()
        }
    }

    nonisolated static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// The custom play/pause control, standing in for the default player chrome this
    /// editor doesn't show.
    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    /// The custom mute control, standing in for the default player chrome this editor
    /// doesn't show.
    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// Drags the start handle to `time`, clamped into `[0, end - minimumClipDuration]`.
    /// Pauses and seeks to the handle so the preview shows the frame being trimmed to. A
    /// no-op until `prepare()` has loaded the duration.
    func trimStart(to time: TimeInterval) {
        guard duration != nil else { return }
        let newWindow = Self.trimmedStart(window, to: time)
        guard newWindow != window else { return }
        isTrimming = true
        player.pause()
        window = newWindow
        seek(to: newWindow.startTime)
    }

    /// Drags the end handle to `time`, clamped into `[start + minimumClipDuration,
    /// duration]`. Same pause-and-seek behavior as the start handle.
    func trimEnd(to time: TimeInterval) {
        guard let duration else { return }
        let newWindow = Self.trimmedEnd(window, to: time, duration: duration)
        guard newWindow != window else { return }
        isTrimming = true
        player.pause()
        window = newWindow
        seek(to: newWindow.endTime)
    }

    /// Called when a handle drag ends: resumes the preview loop from the new start,
    /// unless the user had manually paused — dragging a handle must not overrule Pause.
    ///
    /// A follow crop still all Auto follow's — every keyframe as Auto follow wrote it —
    /// re-tracks the new window, positions and zoom, at the same turn, moving there the way
    /// Auto follow does. A keyframe the user set never moves on a trim.
    func finishTrim() {
        isTrimming = false
        retrackFollowCrop()
        seek(to: window.startTime)
        if isPlaying {
            player.play()
        }
    }

    private func retrackFollowCrop() {
        guard supportsAutoFollow, let followCrop, followCrop.isUntouchedAutoFollow,
              let overlay = previewOverlay
        else { return }
        guard let fit = autoFollower.fit(
            frames: framesInWindow, cropRect: overlay.cropRect, videoSize: overlay.videoSize,
            rotationRadians: followRotationAtPlayhead)
        else { return }
        var retracked = fit.crop
        retracked.isAutoFollow = followCrop.isAutoFollow
        guard retracked != followCrop else { return }
        withAnimation(Self.fitAnimation) {
            easePan { self.followCrop = retracked }
        }
    }

    /// Applies loaded media info: clamps the draft window into the asset — the detected
    /// window's trailing buffer can overshoot the duration. Internal so tests can drive
    /// the trim math without an asset.
    ///
    /// A clip that opens without a follow crop of its own gets Auto follow's for the
    /// window here, in the same update that first lays the video out, so the picture never
    /// shows another framing first.
    func setMediaInfo(
        duration: TimeInterval, naturalSize: CGSize, preferredTransform: CGAffineTransform,
        frameRate: Double = 30
    ) {
        self.duration = duration
        nominalFrameRate = frameRate
        trackGeometry = VideoTrackGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform)
        window = Self.clamped(window: window, to: duration)
        if followCrop == nil, let overlay = previewOverlay {
            let opening = autoFollower.defaultCrop(
                poseFrames: source.poseFrames, window: window, cropRect: overlay.cropRect, videoSize: overlay.videoSize)
            openingFollowCrop = opening
            followCrop = opening
        }
        rebuildFollowPan()
    }

    /// Clamps a window into `[0, duration]`, keeping at least `minimumClipDuration` where
    /// the duration allows it. Pure so the trim math is unit-testable.
    nonisolated static func clamped(window: TrickWindow, to duration: TimeInterval) -> TrickWindow {
        let endTime = min(max(window.endTime, 0), duration)
        let startTime = min(max(window.startTime, 0), max(endTime - minimumClipDuration, 0))
        return TrickWindow(startTime: startTime, endTime: endTime)
    }

    /// Drags the start handle of `window` to `time`, clamped into `[0, end -
    /// minimumClipDuration]`. Pure (and `static`) so the clamp rule is unit-testable
    /// without a player or an asset.
    nonisolated static func trimmedStart(
        _ window: TrickWindow, to time: TimeInterval
    ) -> TrickWindow {
        let latestStart = max(window.endTime - minimumClipDuration, 0)
        let newStart = min(max(time, 0), latestStart)
        return TrickWindow(startTime: newStart, endTime: window.endTime)
    }

    /// Drags the end handle of `window` to `time`, clamped into `[start +
    /// minimumClipDuration, duration]`. Pure for the same shared-rule reason as
    /// `trimmedStart(_:to:)`.
    nonisolated static func trimmedEnd(
        _ window: TrickWindow, to time: TimeInterval, duration: TimeInterval
    ) -> TrickWindow {
        let earliestEnd = min(window.startTime + minimumClipDuration, duration)
        let newEnd = max(min(time, duration), earliestEnd)
        return TrickWindow(startTime: window.startTime, endTime: newEnd)
    }

    /// The sampled pose frames inside the draft window: what Auto follow fits.
    private var framesInWindow: [PoseFrameResult] {
        source.poseFrames.filter {
            $0.timestamp >= window.startTime && $0.timestamp <= window.endTime
        }
    }

    /// (Re)starts the preview loop over the draft window. Clears the trim latch first:
    /// the loop-back guard is only meaningful during an active drag, and re-arming the
    /// loop always starts from a non-dragging state.
    ///
    /// Internal rather than private, like `isTrimming` above, so the auto-play gate is
    /// assertable: the only other way in is `prepare()`, which needs a loadable asset.
    func startPreview() {
        isTrimming = false
        armPlayer()
        seek(to: window.startTime)
        // The preview parks on the window's first frame instead of looping when the system
        // says not to auto-play; Play then starts it on request.
        guard mayAutoplayLoops() else { return }
        player.play()
        isPlaying = true
    }

    /// Attaches the asset's item, with its composition and the frame output the preview shows
    /// (`PreviewFrames`), the periodic observer and the end-of-item observer, once each —
    /// everything the preview loop needs short of seeking and playing.
    private func armPlayer() {
        if player.currentItem == nil {
            let item = AVPlayerItem(sdrAsset: source.asset)
            item.videoComposition = previewComposition
            previewFrames.attach(to: item)
            player.replaceCurrentItem(with: item)
        }
        if timeObserver == nil {
            let interval = CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                Task { @MainActor in
                    self?.tick(at: time.seconds)
                }
            }
        }
        if didPlayToEndObserver == nil {
            didPlayToEndObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.tick(at: self?.window.endTime ?? 0)
                }
            }
        }
    }

    /// One preview tick: follows the playhead and loops the draft window. The loop-back
    /// is suppressed while a handle drag is in flight — the drag's seek lands exactly on
    /// the moved handle, which would otherwise read as the loop point and bounce the
    /// preview back to the window start.
    private func tick(at time: TimeInterval) {
        playbackTime = time
        if isPlaying,
           Self.shouldLoopBack(at: time, window: window, isTrimming: isTrimming || isPresenterScrubbing) {
            loopBack()
        }
    }

    /// Returns the preview to the window's start and keeps it playing. The player pauses
    /// itself when the item plays out — a window ending at the asset's end gets there —
    /// so a seek alone would leave the preview stopped on the first frame; `isPlaying`
    /// is the user's intent, and the player follows it.
    private func loopBack() {
        seek(to: window.startTime)
        if isPlaying, player.rate == 0 {
            player.play()
        }
    }

    /// The preview loop's decision, extracted so the drag interaction is unit-testable: a
    /// tick at (or epsilon-past) the window end loops back to the start, unless a handle
    /// drag is in flight. The epsilon keeps the last frame from flashing past the end
    /// handle before the loop-back seek lands.
    nonisolated static func shouldLoopBack(
        at time: TimeInterval, window: TrickWindow, isTrimming: Bool
    ) -> Bool {
        !isTrimming && time >= window.endTime - 0.05
    }

    private func seek(to time: TimeInterval) {
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTime = time
    }
}
