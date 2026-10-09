import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI

/// The clip editor's state (`docs/UIUX.md` § "Clip Detail / Editor").
///
/// Holds the draft trim window, the crop rect the clip opened with, and the crop adjustment
/// on top of it (pinch/rotate/drag, or the Auto crop and Auto rotate fits); the view
/// commits `result` on back-navigation or Delete — no separate save step, per the design
/// doc. The crop rect never moves on its own: it is the anchor the marker is laid out
/// from, and only the user's gestures and the Auto fits change the framing, as an
/// adjustment on it. Trimming in particular leaves the framing alone — the framing is
/// what the user last set, and a handle drag is a trim, not a re-crop; Auto crop is the
/// one tap that refits the framing to whatever the trimmed window holds. Playback loops
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
    /// fills it, and every change to the framing is carried by `cropAdjustment`.
    let cropRect: NormalizedRect
    /// The adjustment on top of `cropRect` — the user's pinch/rotate/drag, or Auto crop's
    /// and Auto rotate's fits — applied to the video while the crop rect's on-screen
    /// marker stays fixed. Trimming never touches it.
    @Published private(set) var cropAdjustment: CropAdjustment
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
    /// True while the last Auto crop's fit is what's on screen — what turns the button into
    /// "Reset crop", which returns the framing to the whole source video (`resetCrop`).
    /// Cleared by the reset itself and by any manual crop gesture, since the fit is then no
    /// longer what's on screen. The reset leaves the rotation alone, as Auto crop itself
    /// does.
    @Published private(set) var isAutoCropApplied = false
    /// True while the last Auto rotate's turn is what's on screen — "Reset rotate", which
    /// returns the video to its original, unrotated orientation. Cleared the same way
    /// `isAutoCropApplied` is.
    @Published private(set) var isAutoRotateApplied = false

    /// The pinch's committed scale is clamped here, and Auto crop's fitted scale too, so
    /// neither can shrink the video to a sliver or blow it up past usefulness.
    nonisolated static let scaleRange: ClosedRange<CGFloat> = 0.2...8

    /// How Auto crop and Auto rotate move the video to their result: along the same
    /// scale/rotation/offset the fingers drive, over this curve, so the user sees what
    /// changed and from where (`docs/UIUX.md` § "An automatic change moves, it never cuts").
    nonisolated static let fitAnimation: Animation = .easeInOut(duration: 0.4)

    /// The player the view renders. Created up front so `VideoPlayer` never sees a nil
    /// player; the item is attached in `prepare()`.
    let player = AVPlayer()

    /// What Auto rotate levels by: `ClipLeveler` in the app (the take's roll track, else the
    /// picture's horizon), a canned answer in tests.
    typealias LevelingRotation = @Sendable (AVAsset, TrickWindow) async throws -> Double?

    private let source: ClipEditorSource
    private let calculator: CropRectCalculator
    private let levelingRotation: LevelingRotation
    private var timeObserver: Any?
    /// The item's end-of-playback observer: a window ending at the asset's end plays the
    /// item out, which pauses the player on its own (`AVPlayer`'s default
    /// `actionAtItemEnd`), and the periodic tick's loop-back seek alone would land on a
    /// paused player — the preview would stop at the end of the clip instead of looping.
    private var didPlayToEndObserver: NSObjectProtocol?
    private var naturalSize: CGSize?
    private var preferredTransform = CGAffineTransform.identity
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
    /// (`trimEnd` sets it, `finishTrim` clears it) — a mutation probe showed no test
    /// discriminated this guard while it was unreadable.
    private(set) var isTrimming = false

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
        levelingRotation: @escaping LevelingRotation = { try await ClipLeveler.levelingRotation(in: $0, window: $1) }
    ) {
        self.source = source
        self.calculator = calculator
        self.levelingRotation = levelingRotation
        self.window = source.window
        self.cropRect = source.cropRect
        self.cropAdjustment = source.cropAdjustment
    }

    /// The committed edits, in the shape the clip list applies to its item.
    var result: ClipEditorResult {
        ClipEditorResult(window: window, cropRect: cropRect, cropAdjustment: cropAdjustment)
    }

    /// "2.4s"-style duration of the draft window, via the one shared clip-duration
    /// formatter — the same window must read the same on the triage card and the
    /// export confirmation row.
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

    /// The stage geometry in one value: the displayed (upright) frame size plus the crop
    /// rect mapped into that space. Nil until media info loads; the view lays the video out
    /// under the fixed marker from it.
    var previewOverlay: (videoSize: CGSize, cropRect: CGRect)? {
        guard let naturalSize,
              let crop = Self.displayedCropRect(
                  cropRect: cropRect,
                  naturalSize: naturalSize,
                  preferredTransform: preferredTransform)
        else { return nil }
        let videoSize = Self.displayedSize(
            naturalSize: naturalSize, preferredTransform: preferredTransform)
        return (videoSize: videoSize, cropRect: crop)
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
        setMediaInfo(
            duration: assetDuration.seconds,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform)
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
        armPlayer()
        player.pause()
        await scrub(to: time)
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

    /// Applies a pinch's cumulative magnification since the gesture started: `delta`
    /// multiplies onto the committed scale (standard iOS pinch-to-zoom — spreading
    /// fingers zooms in), clamped so the video can't shrink to a sliver or blow up past
    /// usefulness.
    func applyCropScale(_ delta: CGFloat) {
        guard delta.isFinite, delta > 0 else { return }
        guard delta != 1 else { return }
        clearAutoFits()
        cropAdjustment.scale = Self.clampedScale(cropAdjustment.scale * delta)
    }

    /// Applies a two-finger rotation's cumulative angle since the gesture started.
    func applyCropRotation(_ deltaRadians: Double) {
        guard deltaRadians.isFinite else { return }
        guard deltaRadians != 0 else { return }
        clearAutoFits()
        cropAdjustment.rotationRadians += deltaRadians
    }

    /// A manual gesture takes over the framing from both automatic fits at once: whatever
    /// Auto crop or Auto rotate put on screen is no longer what's there, so both buttons
    /// return to offering their fit. The gesture methods above and below call this only for
    /// a gesture that actually changed something — a pinch that ends where it started is
    /// not an edit.
    private func clearAutoFits() {
        isAutoCropApplied = false
        isAutoRotateApplied = false
    }

    /// Applies a drag's cumulative translation since the gesture started. `screenPoints`
    /// is the raw gesture translation in the stage's on-screen point space;
    /// `previewScale` is the stage's on-screen points per displayed pixel
    /// (`ClipEditorStage.VideoPlacement.pointsPerDisplayedPixel`). Dividing by it converts
    /// into the displayed-pixel space `ClipExportTransform.make` and `ClipThumbnailLoader`
    /// both expect `cropAdjustment.offset` to already be in.
    func applyCropOffset(_ screenPoints: CGSize, previewScale: CGFloat) {
        guard screenPoints.width.isFinite, screenPoints.height.isFinite,
              previewScale.isFinite, previewScale > 0
        else { return }
        guard screenPoints != .zero else { return }
        clearAutoFits()
        cropAdjustment.offset.width += screenPoints.width / previewScale
        cropAdjustment.offset.height += screenPoints.height / previewScale
    }

    /// The "Auto crop" action: frames every located keypoint in the draft window inside the
    /// marker, at the current rotation — the one way the framing follows the trimmed
    /// window. The rotation itself is kept — Auto rotate (or two fingers) owns it — and
    /// the scale and offset are replaced by the fit, so a manual pinch or drag is
    /// discarded. At zero rotation the fit is the pipeline's own framing for the window,
    /// so on an untrimmed clip the adjustment returns to identity. A window with no
    /// located keypoints leaves the adjustment alone. The video moves to the fit over
    /// `fitAnimation` rather than cutting to it.
    func autoCrop() {
        guard let overlay = previewOverlay,
              let adjustment = Self.autoCropAdjustment(
                  normalizedKeypoints: CropRectCalculator.locatedPoints(in: framesInWindow),
                  cropRect: overlay.cropRect,
                  videoSize: overlay.videoSize,
                  rotationRadians: cropAdjustment.rotationRadians,
                  calculator: calculator)
        else { return }
        withAnimation(Self.fitAnimation) {
            cropAdjustment = adjustment
        }
        isAutoCropApplied = true
    }

    /// Whether Auto crop has anything to fit: the clip came with pose analysis. A clip added
    /// by hand ("Clip manually") never does, so for it the editor offers Reset crop alone,
    /// enabled while `isCropAdjusted` — an Auto crop whose tap could never change anything
    /// reads as broken.
    var supportsAutoCrop: Bool {
        !source.poseFrames.isEmpty
    }

    /// Whether the framing differs from the whole source video — the full frame centered in
    /// the marker at the current rotation (`fullFrameAdjustment`), which is what Reset crop
    /// returns to. The rotation alone doesn't count: Reset rotate owns it. `false` until
    /// media info has loaded, since there is no framing to compare yet.
    var isCropAdjusted: Bool {
        guard let overlay = previewOverlay else { return false }
        let fullFrame = Self.fullFrameAdjustment(
            cropRect: overlay.cropRect, videoSize: overlay.videoSize,
            rotationRadians: cropAdjustment.rotationRadians, calculator: calculator)
        let tolerance: CGFloat = 1e-6
        return abs(cropAdjustment.scale - fullFrame.scale) > tolerance
            || abs(cropAdjustment.offset.width - fullFrame.offset.width) > tolerance
            || abs(cropAdjustment.offset.height - fullFrame.offset.height) > tolerance
    }

    /// "Reset crop": returns the framing to the whole source video — the full frame centered
    /// in the marker at the marker's ratio, the way a clip added by hand opens — moving
    /// there the same way the fit moved. Not the detected crop and not the framing from
    /// just before the Auto tap: the reset is the way back to the original video whatever
    /// was done in between. The rotation stays, as Auto crop left it alone too. On a clip
    /// with pose analysis the button then offers Auto crop again; on one without, it is
    /// the only crop button and simply disables until the framing moves again.
    func resetCrop() {
        guard let overlay = previewOverlay, isAutoCropApplied || isCropAdjusted else { return }
        isAutoCropApplied = false
        let adjustment = Self.fullFrameAdjustment(
            cropRect: overlay.cropRect, videoSize: overlay.videoSize,
            rotationRadians: cropAdjustment.rotationRadians, calculator: calculator)
        withAnimation(Self.fitAnimation) {
            cropAdjustment = adjustment
        }
    }

    /// The adjustment that shows the whole source frame in the marker: the full frame's own
    /// marker-ratio box (`markerBox`, the same box a full-frame crop rect lays the marker out
    /// from) scaled and moved onto the marker, in the same terms `autoCropAdjustment`
    /// expresses its fit — the scale is the two boxes' width ratio, the offset moves the
    /// box's center onto the marker's after the scale. The rotation passes through
    /// untouched, and the frame is shown turned by it about the marker's center: the video
    /// turns about the crop center before the offset applies, so the box's center is turned
    /// the same way before the offset that cancels it is read off. For a clip whose crop
    /// rect is already the full frame this is the identity.
    nonisolated static func fullFrameAdjustment(
        cropRect: CGRect, videoSize: CGSize, rotationRadians: Double, calculator: CropRectCalculator
    ) -> CropAdjustment {
        let aspectRatio = CGFloat(calculator.targetAspectRatio)
        let marker = markerBox(around: cropRect, aspectRatio: aspectRatio)
        let center = CGPoint(x: cropRect.midX, y: cropRect.midY)
        let fullFrame = markerBox(around: CGRect(origin: .zero, size: videoSize), aspectRatio: aspectRatio)
            .offsetBy(dx: -center.x, dy: -center.y)
        guard marker.width > 0, fullFrame.width > 0 else {
            return CropAdjustment(scale: 1, rotationRadians: rotationRadians, offset: .zero)
        }
        let scale = clampedScale(marker.width / fullFrame.width)
        let turnedCenter = CGPoint(x: fullFrame.midX, y: fullFrame.midY)
            .applying(CGAffineTransform(rotationAngle: rotationRadians))
        return CropAdjustment(
            scale: scale,
            rotationRadians: rotationRadians,
            offset: CGSize(width: -turnedCenter.x * scale, height: -turnedCenter.y * scale))
    }

    /// "Reset rotate": returns the video to its original, unrotated orientation, moving
    /// there the same way the turn moved. Scale and offset stay. The button then offers
    /// Auto rotate again.
    func resetRotate() {
        guard isAutoRotateApplied else { return }
        isAutoRotateApplied = false
        withAnimation(Self.fitAnimation) {
            cropAdjustment.rotationRadians = CropAdjustment.identity.rotationRadians
        }
    }

    /// The adjustment that frames `normalizedKeypoints` in the marker at `rotationRadians`,
    /// or `nil` when there is nothing to frame. Pure, so the fit is unit-testable without a
    /// player; the rotated case is the discriminating one.
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
    /// measured on the source, not on the rotated preview. Scale and offset stay as they
    /// are; Auto crop refits them if the turn carries a limb out of the marker. One
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
                    cropAdjustment.rotationRadians = rotation
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

    nonisolated private static func clampedScale(_ scale: CGFloat) -> CGFloat {
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
    func finishTrim() {
        isTrimming = false
        seek(to: window.startTime)
        if isPlaying {
            player.play()
        }
    }

    /// Applies loaded media info: clamps the draft window into the asset — the detected
    /// window's trailing buffer can overshoot the duration. Internal so tests can drive
    /// the trim math without an asset.
    func setMediaInfo(
        duration: TimeInterval, naturalSize: CGSize, preferredTransform: CGAffineTransform
    ) {
        self.duration = duration
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        window = Self.clamped(window: window, to: duration)
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

    /// Maps the crop rect from `NormalizedRect`'s space contract — the decoded frames'
    /// normalized space (display orientation, y down from the top), matching the pose
    /// keypoints it is built from — into displayed pixel space, matching what the player
    /// shows. `nil` for degenerate inputs.
    ///
    /// Pure so the geometry is unit-testable; the 90°-rotation case is the discriminating
    /// one.
    nonisolated static func displayedCropRect(
        cropRect: NormalizedRect,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGRect? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        // cropRect is already normalized in display orientation, so denormalize in the
        // displayed size directly — no trip through preferredTransform needed.
        let displayedSize = Self.displayedSize(
            naturalSize: naturalSize, preferredTransform: preferredTransform)
        let displayed = cropRect.denormalized(in: displayedSize)
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        return displayed
    }

    /// The frame size as the player shows it: the encoded frame's corners through
    /// `preferredTransform`, so a 90°-rotated track reports portrait dimensions.
    nonisolated static func displayedSize(
        naturalSize: CGSize, preferredTransform: CGAffineTransform
    ) -> CGSize {
        boundingBox(of: CGRect(origin: .zero, size: naturalSize).corners.map {
            $0.applying(preferredTransform)
        }).size
    }

    /// The sampled pose frames inside the draft window: what Auto crop fits.
    private var framesInWindow: [PoseFrameResult] {
        source.poseFrames.filter {
            $0.timestamp >= window.startTime && $0.timestamp <= window.endTime
        }
    }

    /// (Re)starts the preview loop over the draft window. Clears the trim latch first:
    /// the loop-back guard is only meaningful during an active drag, and re-arming the
    /// loop always starts from a non-dragging state.
    private func startPreview() {
        isTrimming = false
        armPlayer()
        seek(to: window.startTime)
        player.play()
        isPlaying = true
    }

    /// Attaches the asset's item, the periodic observer and the end-of-item observer, once
    /// each — everything the preview loop needs short of seeking and playing.
    private func armPlayer() {
        if player.currentItem == nil {
            player.replaceCurrentItem(with: AVPlayerItem(sdrAsset: source.asset))
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
        if Self.shouldLoopBack(at: time, window: window, isTrimming: isTrimming || isPresenterScrubbing) {
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

    private nonisolated static func boundingBox(of points: [CGPoint]) -> CGRect {
        let xValues = points.map(\.x), yValues = points.map(\.y)
        guard let minX = xValues.min(), let maxX = xValues.max(),
              let minY = yValues.min(), let maxY = yValues.max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension CGRect {
    var corners: [CGPoint] {
        [origin,
         CGPoint(x: maxX, y: minY),
         CGPoint(x: minX, y: maxY),
         CGPoint(x: maxX, y: maxY)]
    }
}
