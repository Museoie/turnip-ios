import AVFoundation
import CoreGraphics
import Foundation

/// The clip editor's state (`docs/UIUX.md` § "Clip Detail / Editor").
///
/// Holds the draft trim window, the live crop rect, and the keep/discard decision; the view
/// commits `result` on back-navigation — no separate save step, per the design doc.
/// Trimming re-derives the crop rect from the pose frames in play via `CropRectCalculator`:
/// the rect is a function of the window, so it has to follow the handles. Playback loops
/// the draft window; dragging a handle pauses and seeks to the handle so the preview shows
/// the frame being trimmed to.
///
/// `@MainActor` throughout: the player, its time observer, and the draft state all live on
/// the main thread. The recompute filters the sampled frames and runs the crop calculator's
/// pure geometry — sub-millisecond at the pipeline's ~10 kept frames per second of video —
/// so it runs inline on every drag tick without dropping the gesture.
@MainActor
final class ClipEditorViewModel: ObservableObject {
    /// The shortest clip the trim handles can produce. Below this the export would be a
    /// flicker of a few frames; the handles stop instead of crossing.
    static let minimumClipDuration: TimeInterval = 0.5

    @Published private(set) var window: TrickWindow
    @Published private(set) var cropRect: NormalizedRect
    @Published var isKept: Bool
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var playbackTime: TimeInterval = 0

    /// Set when `prepare()` can't load the asset: the view swaps the loading
    /// spinner for an error message instead of spinning forever.
    @Published private(set) var failedToLoad = false

    /// The player the view renders. Created up front so `VideoPlayer` never sees a nil
    /// player; the item is attached in `prepare()`.
    let player = AVPlayer()

    private let source: ClipEditorSource
    private let calculator: CropRectCalculator
    private var timeObserver: Any?
    private var naturalSize: CGSize?
    private var preferredTransform = CGAffineTransform.identity

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

    init(source: ClipEditorSource, calculator: CropRectCalculator = CropRectCalculator()) {
        self.source = source
        self.calculator = calculator
        self.window = source.window
        self.cropRect = source.cropRect
        self.isKept = source.isKept
    }

    /// The committed edits, in the shape the clip list applies to its item.
    var result: ClipEditorResult {
        ClipEditorResult(window: window, cropRect: cropRect, isKept: isKept)
    }

    /// "2.4s"-style duration of the draft window, via the shared timestamp formatter.
    var durationLabel: String {
        Self.timeLabel(window.endTime - window.startTime)
    }

    /// "1.2s"-style timestamp, built by hand so the decimal separator can't follow the
    /// device locale. Shared by the duration label and the slider's labels so the two
    /// copies can't drift apart.
    nonisolated static func timeLabel(_ time: TimeInterval) -> String {
        let tenths = (time * 10).rounded() / 10
        return "\(tenths)s"
    }

    /// The timeline's visible range: the draft window plus context on both sides, so the
    /// handles stay draggable on a multi-minute video. Nil until the duration loads.
    var visibleRange: ClosedRange<TimeInterval>? {
        guard let duration, duration > 0 else { return nil }
        let padding = max(window.endTime - window.startTime, 2.0)
        let lower = max(window.startTime - padding, 0)
        let upper = min(window.endTime + padding, duration)
        guard lower < upper else { return nil }
        return lower...upper
    }

    /// The overlay geometry in one value: the displayed (upright) frame size plus the crop
    /// rect mapped into that space. Nil until media info loads; the view draws the dimmed
    /// surround from it.
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
        startPreview()
    }

    /// Stops playback and drops the time observer. Called when the view disappears.
    /// Also clears the trim latch: if the disappearing view was mid-drag, the gesture's
    /// `onEnded` never fired, and re-appearing must re-arm a clean loop via `prepare()`.
    func teardown() {
        isTrimming = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
    }

    /// The keep/discard toggle, mirroring the clip list's quick action.
    func toggleKeep() {
        isKept.toggle()
    }

    /// Drags the start handle to `time`, clamped into `[0, end - minimumClipDuration]`.
    /// Pauses and seeks to the handle so the preview shows the frame being trimmed to. A
    /// no-op until `prepare()` has loaded the duration.
    func trimStart(to time: TimeInterval) {
        guard duration != nil else { return }
        let latestStart = max(window.endTime - Self.minimumClipDuration, 0)
        let newStart = min(max(time, 0), latestStart)
        guard newStart != window.startTime else { return }
        isTrimming = true
        player.pause()
        window = TrickWindow(startTime: newStart, endTime: window.endTime)
        seek(to: newStart)
        recomputeCropRect()
    }

    /// Drags the end handle to `time`, clamped into `[start + minimumClipDuration,
    /// duration]`. Same pause-and-seek behavior as the start handle.
    func trimEnd(to time: TimeInterval) {
        guard let duration else { return }
        let earliestEnd = min(window.startTime + Self.minimumClipDuration, duration)
        let newEnd = max(min(time, duration), earliestEnd)
        guard newEnd != window.endTime else { return }
        isTrimming = true
        player.pause()
        window = TrickWindow(startTime: window.startTime, endTime: newEnd)
        seek(to: newEnd)
        recomputeCropRect()
    }

    /// Called when a handle drag ends: resumes the preview loop from the new start.
    func finishTrim() {
        isTrimming = false
        seek(to: window.startTime)
        player.play()
    }

    /// Applies loaded media info: clamps the draft window into the asset — the detected
    /// window's trailing buffer can overshoot the duration — and re-derives the crop rect
    /// for the clamped window. Internal so tests can drive the trim math without an asset.
    func setMediaInfo(
        duration: TimeInterval, naturalSize: CGSize, preferredTransform: CGAffineTransform
    ) {
        self.duration = duration
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        window = Self.clamped(window: window, to: duration)
        recomputeCropRect()
    }

    /// Clamps a window into `[0, duration]`, keeping at least `minimumClipDuration` where
    /// the duration allows it. Pure so the trim math is unit-testable.
    nonisolated static func clamped(window: TrickWindow, to duration: TimeInterval) -> TrickWindow {
        let endTime = min(max(window.endTime, 0), duration)
        let startTime = min(max(window.startTime, 0), max(endTime - minimumClipDuration, 0))
        return TrickWindow(startTime: startTime, endTime: endTime)
    }

    /// Maps the crop rect from `NormalizedRect`'s space contract — the encoded frame's
    /// pixel space, top-left origin, `preferredTransform` not applied — into the displayed
    /// frame's space, matching what the player shows. `nil` for degenerate inputs.
    ///
    /// Pure so the geometry is unit-testable; the 90°-rotation case is the discriminating
    /// one.
    nonisolated static func displayedCropRect(
        cropRect: NormalizedRect,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGRect? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        let encoded = cropRect.denormalized(in: naturalSize)
        guard encoded.width > 0, encoded.height > 0 else { return nil }
        return boundingBox(of: encoded.corners.map { $0.applying(preferredTransform) })
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

    /// Re-derives the crop rect from the pose frames inside the draft window. When the
    /// adjusted window holds no usable keypoints the last good rect is kept: jumping to
    /// the full frame mid-drag would yank the preview while the user is still moving the
    /// handle through a low-confidence stretch.
    private func recomputeCropRect() {
        guard let naturalSize else { return }
        let inWindow = source.poseFrames.filter {
            $0.timestamp >= window.startTime && $0.timestamp <= window.endTime
        }
        if let rect = calculator.cropRect(for: inWindow, sourcePixelSize: naturalSize) {
            cropRect = rect
        }
    }

    /// (Re)starts the preview loop over the draft window. Clears the trim latch first:
    /// the loop-back guard is only meaningful during an active drag, and re-arming the
    /// loop always starts from a non-dragging state.
    private func startPreview() {
        isTrimming = false
        if player.currentItem == nil {
            player.replaceCurrentItem(with: AVPlayerItem(asset: source.asset))
        }
        if timeObserver == nil {
            let interval = CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
                [weak self] time in
                Task { @MainActor in
                    self?.tick(at: time.seconds)
                }
            }
        }
        seek(to: window.startTime)
        player.play()
    }

    /// One preview tick: follows the playhead and loops the draft window. The loop-back
    /// is suppressed while a handle drag is in flight — the drag's seek lands exactly on
    /// the moved handle, which would otherwise read as the loop point and bounce the
    /// preview back to the window start.
    private func tick(at time: TimeInterval) {
        playbackTime = time
        if Self.shouldLoopBack(at: time, window: window, isTrimming: isTrimming) {
            seek(to: window.startTime)
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
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
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
