import AVFoundation
import SwiftUI

/// The per-clip editor (`docs/UIUX.md` § "Clip Detail / Editor"): full-screen,
/// one clip at a time — the trimmed clip looping under a crop marker that is one rectangle of
/// the clip's shape on screen, with the video laid out so the clip's crop rect fills it and the
/// rest of the frame showing frosted around it, edge to edge, and the crop following the
/// athlete (pinch to zoom, rotate with two fingers, drag to reposition the video at the
/// playhead's moment), corner handles that reshape the marker, the Auto follow and Auto rotate
/// buttons that fit the video under the marker for the user, the follow lane, plus a scrub bar
/// with start/end drag handles.
///
/// Back-navigation closes the editor via the top row's own action — `onCommit` fires
/// synchronously from that tap, before the enclosing presentation dismisses, rather than
/// from `onDisappear`: mutating the presenting screen's state while the dismiss transition
/// is still animating would race the dismiss and swallow the back chevron's tap.
struct ClipEditorView: View {
    @StateObject private var viewModel: ClipEditorViewModel
    /// The final editor state, committed on back-navigation — no separate save step,
    /// per the design doc.
    let onCommit: (ClipEditorResult) -> Void
    /// Intercepts the back button's close instead of calling `dismiss()` directly, so
    /// a presenter can animate its own reverse transition before the cover actually
    /// goes away. `nil` (the default) falls back to `dismiss()`, which keeps
    /// `ScreenshotHarness` and this file's own `#Preview` working unchanged.
    var onRequestClose: (() -> Void)?
    /// A presenter's own swipe-to-dismiss gesture, planted behind this view's content
    /// (see `ClipExpansionContainer`'s doc comment for why it has to live here rather
    /// than behind this view in the presenter's own hierarchy) — `nil` for callers
    /// that don't need it.
    var dismissGesture: AnyGesture<DragGesture.Value>?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.expansionHasLanded) private var expansionHasLanded
    /// The crop gestures' in-flight deltas, drawn on top of the follow crop until the gesture
    /// commits into the view model (`CropGestureSurface`).
    @State private var gestureScale: CGFloat = 1
    @State private var gestureRotation: Angle = .zero
    @State private var gestureOffset: CGSize = .zero
    /// A gesture on the crop area, from its first finger down to its last one up: it writes the
    /// playhead's keyframe once, when both are over (`commitFollowGesture`).
    @State private var followGesture = FollowGestureProgress()
    /// Where the layout placeholder in `chrome` sits (global space): the band between the header
    /// row and the bottom controls, where the crop gestures are taken. Fixed per device — it
    /// never depends on the clip.
    @State private var stageFrame: CGRect = .zero
    /// The marker as a corner handle is dragging it (global space), drawn in place of the settled
    /// marker until the drag ends and the clip takes its shape (`reshapeGesture`). `nil` while
    /// no handle is held.
    @State private var reshapedMarker: CGRect?
    /// True while a corner handle is held. `@GestureState`, so a drag the system takes still
    /// resets it although its `onEnded` never runs, which drops the drawn shape uncommitted.
    @GestureState private var isReshaping = false

    init(
        source: ClipEditorSource,
        onCommit: @escaping (ClipEditorResult) -> Void,
        onRequestClose: (() -> Void)? = nil,
        dismissGesture: AnyGesture<DragGesture.Value>? = nil
    ) {
        self.init(
            viewModel: ClipEditorViewModel(source: source),
            onCommit: onCommit,
            onRequestClose: onRequestClose,
            dismissGesture: dismissGesture)
    }

    /// Renders a view model the presenter owns — `ClipExpansionContainer` keeps the same
    /// player on screen in its flying card, so the editor and the card show the same
    /// frame at the instant one replaces the other.
    init(
        viewModel: ClipEditorViewModel,
        onCommit: @escaping (ClipEditorResult) -> Void,
        onRequestClose: (() -> Void)? = nil,
        dismissGesture: AnyGesture<DragGesture.Value>? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onCommit = onCommit
        self.onRequestClose = onRequestClose
        self.dismissGesture = dismissGesture
    }

    private func close() {
        if let onRequestClose {
            onRequestClose()
        } else {
            dismiss()
        }
    }

    /// The presenter's swipe-to-dismiss surface: the band above the crop marker only — the
    /// top row and the status-bar band over it — never the controls below the marker or
    /// their margins, where a downward drag reads as a slip off a button or the slider.
    @ViewBuilder
    private var dismissGestureLayer: some View {
        if let dismissGesture {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dismissGesture)
                    .frame(height: max(markerFrame.minY - proxy.frame(in: .global).minY, 0))
            }
            // Edge to edge, so the status-bar band above the top row counts too.
            .ignoresSafeArea()
        }
    }

    /// The crop marker's frame, in global space: the largest rectangle of the clip's shape
    /// (`ClipEditorViewModel.targetAspectRatio`) centered in the stage, the same for every clip of
    /// that shape. Reported to a presenting `ClipExpansionContainer` as the part of the screen its
    /// flying card's window starts on — the settled marker, never one a handle is mid-drag on.
    private var markerFrame: CGRect {
        ClipEditorStage.markerRect(in: stageFrame, aspectRatio: viewModel.targetAspectRatio)
    }

    /// The marker as drawn: a handle's drag while one is held, the settled marker otherwise.
    private var shownMarker: CGRect {
        reshapedMarker ?? markerFrame
    }

    var body: some View {
        ZStack {
            stage
            chrome
        }
        .preference(key: ClipEditorCropMarkerFramePreferenceKey.self, value: markerFrame)
        // Behind this view's own content rather than wrapping it, so the dismiss
        // gesture only ever sees the empty space this content doesn't already claim
        // with its own gesture (the stage's band, the top row's buttons) — see
        // `ClipExpansionContainer`'s doc comment for why it has to be attached here
        // rather than behind this whole view in a presenter's own hierarchy.
        .background(dismissGestureLayer)
        // No navigation bar: the bar is the stack's own view laid over this screen, so a
        // drag that starts in its band never reaches the dismiss gesture behind this
        // content. `topRow` draws the same controls as content instead, in the band the
        // bar would occupy (`ScreenHeaderBand`), which leaves the whole area above the
        // marker to that gesture — `ProcessingView` hides its bar for the same reason.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            await viewModel.prepare()
        }
        .onChange(of: isReshaping) { reshaping in
            // A drag whose `onEnded` ran has already committed; one the system took never did,
            // and leaves nothing behind.
            guard !reshaping, reshapedMarker != nil else { return }
            withAnimation(ClipEditorViewModel.fitAnimation) { reshapedMarker = nil }
        }
        .onDisappear {
            viewModel.teardown()
        }
    }

    /// The controls, stacked over the stage: the header row, the stage's own slot (a
    /// placeholder that only measures where the stage is — the stage itself is drawn
    /// underneath, edge to edge, so the video can run under the header and the controls),
    /// and the crop/trim controls at the bottom. The placeholder passes touches through to
    /// the stage's crop gesture beneath it.
    private var chrome: some View {
        VStack(spacing: 0) {
            ScreenHeaderBand { topRow }
            GeometryReader { proxy in
                Color.clear.preference(key: ClipEditorStageFramePreferenceKey.self, value: proxy.frame(in: .global))
            }
            .allowsHitTesting(false)
            // Over the placeholder, not inside it: the placeholder passes touches through,
            // and the notice has to keep its own tap-to-dismiss.
            .overlay(alignment: .top) { notices }
            VStack(spacing: 16) {
                autoFramingButtons
                VStack(spacing: 4) {
                    FollowLaneView(viewModel: viewModel)
                    TrimSliderView(viewModel: viewModel)
                }
            }
            .padding()
        }
        .onPreferenceChange(ClipEditorStageFramePreferenceKey.self) { stageFrame = $0 }
    }

    /// The screen's own top row in place of a navigation bar (see `body`): the back chevron
    /// leading, at the same position as Name Clips' bar this screen flies open from. The title
    /// stays as the screen's VoiceOver header, drawn clear.
    private var topRow: some View {
        ZStack {
            Text("Edit clip")
                .font(.headline)
                .foregroundStyle(.clear)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("clip-editor-title")
            HStack {
                backButton
                Spacer()
            }
        }
    }

    /// Commits the current edits and closes — the back chevron's action. Runs
    /// synchronously with the tap, before `dismiss()` starts the cover's transition, so
    /// the presenting screen's state settles before the animation begins instead of
    /// racing it. The same floating glass chevron `ProcessingView` draws over its video.
    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to clips") {
            onCommit(viewModel.result)
            close()
        }
        .accessibilityIdentifier("clip-editor-back")
    }

    /// The crop stage, edge to edge under the chrome: the video laid out so its crop rect
    /// fills the marker (`ClipEditorStage`), the frosted surround marking what export cuts
    /// away, the marker's outline and corner handles, and — over the stage's own band only —
    /// the pinch/rotate/drag gesture. The video and the overlays take no touches themselves:
    /// the header band and the bottom controls' margins stay with the dismiss gesture behind
    /// this view, and the handles and the playback pill sit on top of the gesture surface.
    private var stage: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let marker = markerFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let shown = shownMarker.offsetBy(dx: -origin.x, dy: -origin.y)
            let band = stageFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let placement = viewModel.previewOverlay.flatMap {
                ClipEditorStage.videoPlacement(videoSize: $0.videoSize, cropRect: $0.cropRect, marker: marker)
            }
            ZStack {
                ClipEditorVideoSurface(
                    frames: viewModel.previewFrames,
                    track: viewModel.trackGeometry,
                    geometry: viewModel.previewOverlay,
                    marker: marker,
                    pan: viewModel.previewPan,
                    gestureScale: gestureScale,
                    gestureRotation: gestureRotation,
                    gestureOffset: gestureOffset)
                // Hidden until an expansion flight's card — the same player, same
                // placement — has landed here; the marker and controls fade in over it.
                .expansionVideoSurface()
                .allowsHitTesting(false)
                if expansionHasLanded {
                    // The same `.thinMaterial` as `PrimaryActionBar`'s bottom bar, with a
                    // hole at the marker: everything export cuts away shows frosted, only
                    // the crop stays sharp. Not drawn while an expansion flight has this view
                    // under partial opacity, where a material can't blur and would render the
                    // frame behind it sharp: the flying card shows the crop alone, and the
                    // frosted frame around it appears with the landing.
                    CropOverlayShape(hole: shown)
                        .fill(.thinMaterial, style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    // The marker's outline comes and goes with the frost, in the same frame,
                    // rather than cross-fading with the rest of the chrome: on a close the
                    // outline would otherwise outlive the frost around the bare crop.
                    Rectangle()
                        .stroke(.white, lineWidth: 2)
                        .frame(width: shown.width, height: shown.height)
                        .position(x: shown.midX, y: shown.midY)
                        .allowsHitTesting(false)
                        // Lets a UI test read the marker's frame, to check a presenting
                        // container's card lands its picture exactly here. Not a control:
                        // the gesture surface below carries the stage's label and hint.
                        .accessibilityIdentifier("crop-marker")
                }
                loadingState(in: marker)
                cropGestureSurface(previewScale: placement?.pointsPerDisplayedPixel ?? 0)
                    .frame(width: band.width, height: band.height)
                    .position(x: band.midX, y: band.midY)
                    // A reshape and a drag, pinch or turn of the video never run at once: the
                    // surface lets go of its touches while a handle is held.
                    .allowsHitTesting(reshapedMarker == nil)
                    .accessibilityElement()
                    .accessibilityLabel("Clip preview with crop area")
                    .accessibilityValue(viewModel.cropAdjustmentDescription)
                    .accessibilityHint("Pinch to zoom, rotate with two fingers, or drag to reposition")
                    .accessibilityIdentifier("clip-editor-crop-surface")
                    .modifier(CropAdjustmentActions(
                        viewModel: viewModel, videoSize: viewModel.previewOverlay?.videoSize ?? .zero,
                        marker: markerFrame, previewScale: placement?.pointsPerDisplayedPixel ?? 0))
                if expansionHasLanded, let placement {
                    markerHandles(around: shown, in: band, previewScale: placement.pointsPerDisplayedPixel)
                }
                playbackControls
                    .frame(width: shown.width, height: shown.height, alignment: .bottom)
                    .position(x: shown.midX, y: shown.midY)
            }
        }
        .ignoresSafeArea()
    }

    /// The marker's four corner handles. Dragging one reshapes the marker with the corner across
    /// from it held still (`ClipEditorStage.resizedMarker`), drawn live as the marker's outline
    /// and frost while the video stays put; letting go gives the clip that shape, and the video
    /// eases so what the drawn rectangle held fills the marker as it settles centered at its new
    /// shape (`ClipEditorViewModel.resizeCrop`). VoiceOver reaches the same through the crop
    /// area's Make crop wider and Make crop taller actions. Each handle's touch target stays
    /// inside the stage `band` (`ClipEditorStage.handleTarget`), so a downward drag above the
    /// band still closes the editor right up to the band's edge, beside the top corners too.
    private func markerHandles(around shown: CGRect, in band: CGRect, previewScale: CGFloat) -> some View {
        ForEach(ClipEditorStage.Corner.allCases, id: \.self) { corner in
            let point = corner.point(of: shown)
            let target = ClipEditorStage.handleTarget(at: point, side: Self.handleTarget, in: band)
            CropCornerHandle(
                corner: corner, vertex: CGPoint(x: point.x - target.minX, y: point.y - target.minY))
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: target.width, height: target.height)
                .contentShape(Rectangle())
                .position(x: target.midX, y: target.midY)
                .gesture(reshapeGesture(corner, previewScale: previewScale))
                .accessibilityHidden(true)
        }
    }

    /// Each handle's touch target, a square over its corner.
    private static let handleTarget: CGFloat = 44

    /// One corner handle's drag: touch-down pauses as the crop's own gestures do, the marker
    /// follows the finger, and the shape is the clip's once the finger lifts. Ignored while a
    /// finger is already on the video.
    private func reshapeGesture(_ corner: ClipEditorStage.Corner, previewScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($isReshaping) { _, reshaping, _ in reshaping = true }
            .onChanged { value in
                if reshapedMarker == nil {
                    guard !followGesture.fingersDown else { return }
                    viewModel.beginFollowTouch()
                }
                reshapedMarker = ClipEditorStage.resizedMarker(
                    markerFrame, corner: corner, translation: value.translation, in: stageFrame)
            }
            .onEnded { _ in
                guard let drawn = reshapedMarker else { return }
                withAnimation(ClipEditorViewModel.fitAnimation) {
                    viewModel.resizeCrop(from: markerFrame, to: drawn, previewScale: previewScale)
                    reshapedMarker = nil
                }
            }
    }

    /// What the marker holds before the video can: a spinner while media info loads, or
    /// the load-failure message in its place.
    @ViewBuilder
    private func loadingState(in marker: CGRect) -> some View {
        if viewModel.failedToLoad {
            StatusStateView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load this clip",
                message: "The video file couldn't be read."
            )
            .frame(width: marker.width, height: marker.height)
            .position(x: marker.midX, y: marker.midY)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Couldn't load this clip. The video file couldn't be read.")
        } else if viewModel.previewOverlay == nil {
            ProgressView()
                .position(x: marker.midX, y: marker.midY)
        }
    }

    /// The pinch (zoom), two-finger rotate, and one-finger drag gestures, all able to run at
    /// once. Each draws its live delta over the follow crop while the fingers move, and the three
    /// set the framing at the playhead's moment: touch-down pauses, and once every finger has
    /// lifted and every one of them has ended, the drag, pinch and turn are written into the
    /// playhead's keyframe together (`ClipEditorViewModel.applyFollowGesture`), in the same update
    /// that takes the live deltas off, so the picture doesn't move at the hand-over; a cancelled
    /// gesture leaves nothing behind. `previewScale` (on-screen points per displayed pixel) only
    /// matters to the drag — scale and rotation are unit-agnostic.
    private func cropGestureSurface(previewScale: CGFloat) -> some View {
        CropGestureSurface(
            onDrag: { handleDrag($0, previewScale: previewScale) },
            onPinch: { handlePinch($0, previewScale: previewScale) },
            onRotate: { handleRotate($0, previewScale: previewScale) },
            onTouchDown: {
                // A gesture whose last touch never reported its end still commits before the
                // next begins, rather than leaving its live delta on the picture.
                if followGesture.active.isEmpty { commitFollowGesture(previewScale: previewScale) }
                followGesture = FollowGestureProgress(fingersDown: true)
                viewModel.beginFollowTouch()
            },
            onTouchesUp: {
                followGesture.fingersDown = false
                commitFollowGesture(previewScale: previewScale)
            })
    }

    private func handleDrag(_ phase: CropGestureSurface.Phase<CGSize>, previewScale: CGFloat) {
        switch phase {
        case .changed(let translation):
            gestureOffset = translation
            followGesture.active.insert(.drag)
        case .ended(let translation):
            gestureOffset = translation
            followGesture.active.remove(.drag)
            commitFollowGesture(previewScale: previewScale)
        case .cancelled:
            cancelFollowGesture()
        }
    }

    private func handlePinch(_ phase: CropGestureSurface.Phase<CGFloat>, previewScale: CGFloat) {
        switch phase {
        case .changed(let scale):
            gestureScale = scale
            followGesture.active.insert(.pinch)
        case .ended(let scale):
            gestureScale = scale
            followGesture.active.remove(.pinch)
            commitFollowGesture(previewScale: previewScale)
        case .cancelled:
            cancelFollowGesture()
        }
    }

    private func handleRotate(_ phase: CropGestureSurface.Phase<Double>, previewScale: CGFloat) {
        switch phase {
        case .changed(let radians):
            gestureRotation = .radians(radians)
            followGesture.active.insert(.rotate)
        case .ended(let radians):
            gestureRotation = .radians(radians)
            followGesture.active.remove(.rotate)
            commitFollowGesture(previewScale: previewScale)
        case .cancelled:
            cancelFollowGesture()
        }
    }

    /// Writes a gesture into the playhead's keyframe once its fingers are up and its drag,
    /// pinch and turn have all ended, taking their live deltas off in the same update, so the
    /// keyframe lands on the picture already on screen.
    private func commitFollowGesture(previewScale: CGFloat) {
        guard followGesture.active.isEmpty, !followGesture.fingersDown else { return }
        if !followGesture.isCancelled {
            viewModel.applyFollowGesture(
                translation: gestureOffset, previewScale: previewScale, scale: gestureScale,
                rotation: gestureRotation.radians)
        }
        gestureOffset = .zero
        gestureScale = 1
        gestureRotation = .zero
        followGesture.isCancelled = false
    }

    /// The system took a gesture's touches: nothing it did is kept.
    private func cancelFollowGesture() {
        followGesture.isCancelled = true
        followGesture.active = []
        gestureOffset = .zero
        gestureScale = 1
        gestureRotation = .zero
    }

    /// Stands in for the default player chrome this editor doesn't show: play/pause and
    /// mute, alongside `TrimSliderView`'s own timeline below — the three controls this
    /// screen needs, no more.
    private var playbackControls: some View {
        PlaybackControlsPill {
            HStack(spacing: 20) {
                PlayPauseButton(isPlaying: viewModel.isPlaying, action: viewModel.togglePlayback)
                MuteButton(isMuted: viewModel.isMuted, action: viewModel.toggleMute)
            }
        }
        .padding(.bottom, 12)
    }

    /// The two automatic fits, side by side above the follow lane: Auto follow frames the
    /// athlete through the window, Auto rotate levels the clip by its roll track or its horizon.
    /// Each is a toggle: once its fit is on screen the same button reads "Reset follow" /
    /// "Reset rotate" and returns to the original video — the whole frame, unturned —
    /// independently of the other; a change by hand to the follow crop returns both to offering
    /// their fit (`ClipEditorViewModel.isAutoFollowApplied` / `isAutoRotateApplied`). Both wait
    /// for media info — before it there is no stage geometry to fit and no window to sample —
    /// and Auto rotate shows its detection in place of its icon while it runs.
    private var autoFramingButtons: some View {
        HStack(spacing: 12) {
            followButton
            Button {
                if viewModel.isAutoRotateApplied {
                    viewModel.resetRotate()
                } else {
                    viewModel.autoRotate()
                }
            } label: {
                Label {
                    Text(viewModel.isAutoRotateApplied ? "Reset rotate" : "Auto rotate")
                } icon: {
                    if viewModel.isDetectingHorizon {
                        ProgressView()
                    } else if viewModel.isAutoRotateApplied {
                        Image(systemName: "arrow.uturn.backward")
                    } else {
                        Image(systemName: "level")
                    }
                }
            }
            .disabled(viewModel.isDetectingHorizon)
            .accessibilityIdentifier("auto-rotate-button")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.previewOverlay == nil)
        // The labels cut between Auto and Reset: the fit's own `fitAnimation` is in flight
        // in the same update, and a label swap riding it reads as text sliding under a
        // clip while the button changes width. The video moves; the words don't.
        .animation(nil, value: viewModel.isAutoRotateApplied)
        .animation(nil, value: viewModel.isAutoFollowApplied)
    }

    /// The crop button: Auto follow ↔ Reset follow. A clip without pose analysis has nothing for
    /// Auto follow to fit, so it has Reset follow alone: disabled while the framing is the whole
    /// frame, enabled once a pinch, a drag or a keyframe has moved it.
    @ViewBuilder
    private var followButton: some View {
        if viewModel.supportsAutoFollow {
            Button {
                if viewModel.isAutoFollowApplied {
                    viewModel.resetFollow()
                } else {
                    viewModel.autoFollow()
                }
            } label: {
                if viewModel.isAutoFollowApplied {
                    Label("Reset follow", systemImage: "arrow.uturn.backward")
                } else {
                    Label("Auto follow", systemImage: "figure.run")
                }
            }
            .accessibilityIdentifier("auto-follow-button")
        } else {
            Button {
                viewModel.resetFollow()
            } label: {
                Label("Reset follow", systemImage: "arrow.uturn.backward")
            }
            .disabled(!viewModel.isFollowAdjusted)
            .accessibilityIdentifier("reset-follow-button")
        }
    }

    /// The automatic fits' answers when there was nothing to fit, at the top of the stage:
    /// Auto rotate found no horizon in the window (the rotation stays as it was), or Auto
    /// follow found an athlete who stays put (the crop holds one framing).
    @ViewBuilder
    private var notices: some View {
        if viewModel.isShowingNoHorizonNotice {
            GlassNoticeView(message: "No horizon found", isPresented: $viewModel.isShowingNoHorizonNotice)
                .padding(.top, 8)
                .accessibilityIdentifier("no-horizon-notice")
        } else if viewModel.isShowingNothingToFollowNotice {
            GlassNoticeView(message: "Nothing to follow", isPresented: $viewModel.isShowingNothingToFollowNotice)
                .padding(.top, 8)
                .accessibilityIdentifier("nothing-to-follow-notice")
        }
    }
}

/// The video under the editor's crop marker: the player laid out at
/// `ClipEditorStage.videoPlacement`'s frame — the whole displayed frame, placed so the
/// crop rect fills the marker — and drawn by `EditorPlayerView` with the follow crop about
/// the crop rect's center, frame by frame: its center, zoom and turn at each frame
/// (`PreviewPanBlend`). Never clipped: whatever the framing pushes
/// outside the frame's own rect stays visible, the way the export and the tile show it.
/// Shared by the editor's stage and by `ClipExpansionContainer`'s flying card, so the card
/// shows exactly the picture the editor will show — the same player, the same placement —
/// and the cut between the two is invisible. Lays out to whatever size it is given; `marker`
/// is in that space. Until `geometry` is known the player sits hidden at the marker: it has
/// to exist for its first frame to decode (`onReadyForDisplay`), but has no right place yet.
struct ClipEditorVideoSurface: View {
    let frames: PreviewFrames
    /// The source track's geometry (`ClipEditorViewModel.trackGeometry`).
    let track: VideoTrackGeometry?
    /// `ClipEditorViewModel.previewOverlay`: the displayed frame's size and the crop rect in
    /// it, both in displayed pixels. `nil` until media info has loaded.
    let geometry: (videoSize: CGSize, cropRect: CGRect)?
    let marker: CGRect
    /// The framings the preview draws (`ClipEditorViewModel.previewPan`).
    let pan: PreviewPanBlend
    var gestureScale: CGFloat = 1
    var gestureRotation: Angle = .zero
    var gestureOffset: CGSize = .zero
    var onReadyForDisplay: (() -> Void)?

    var body: some View {
        let placement = geometry.flatMap {
            ClipEditorStage.videoPlacement(videoSize: $0.videoSize, cropRect: $0.cropRect, marker: marker)
        }
        let frame = placement?.frame ?? marker
        // In displayed pixels, the zoom and turn's anchor `ClipExportTransform.make` uses.
        let cropCenter = geometry.map { CGPoint(x: $0.cropRect.midX, y: $0.cropRect.midY) } ?? .zero
        EditorPlayerView(
            frames: frames, track: track, cropCenter: cropCenter, pan: pan, gestureScale: gestureScale,
            gestureRotation: gestureRotation.radians, onReadyForDisplay: onReadyForDisplay)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .offset(gestureOffset)
            .opacity(placement == nil ? 0 : 1)
    }
}

/// Where a gesture on the crop area has got to: which of its recognizers are still
/// reporting, whether a finger is still down, and whether the system took it.
private struct FollowGestureProgress {
    enum Recognizer {
        case drag, pinch, rotate
    }

    var active: Set<Recognizer> = []
    var fingersDown = false
    var isCancelled = false
}

/// The stage placeholder's on-screen frame (global space), climbing from the layout placeholder
/// in `ClipEditorView.chrome` to the view that derives the marker from it. Reduces to the
/// latest non-zero report: the placeholder's siblings in the chrome column contribute the
/// zero default, and the last of them would otherwise win the reduction.
private struct ClipEditorStageFramePreferenceKey: NonZeroFramePreferenceKey {}

/// The crop marker's on-screen frame (global space), read by a Photos-style expansion
/// transition presenting this view: the part of the screen the tile's picture lands on,
/// so the flying card's window starts there. Reduces to the latest non-zero report: during
/// the frame this view first mounts, a stale zero default can still be in flight.
struct ClipEditorCropMarkerFramePreferenceKey: NonZeroFramePreferenceKey {}

/// The surround with a hole at the crop marker, for the editor's stage. The hole animates, so it
/// moves with the marker as a reshape settles.
private struct CropOverlayShape: Shape {
    var hole: CGRect

    var animatableData: CGRect.AnimatableData {
        get { hole.animatableData }
        set { hole.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(hole)
        return path
    }
}

/// One corner handle's bracket: two arms along the marker's edges from the corner, pointing
/// into the marker.
private struct CropCornerHandle: Shape {
    let corner: ClipEditorStage.Corner
    /// Where the corner is, in the handle's own frame: its touch target is slid inside the
    /// stage, so the corner isn't always the frame's center.
    let vertex: CGPoint
    private static let armLength: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.minX + vertex.x, y: rect.minY + vertex.y)
        let across: CGFloat = corner == .topLeading || corner == .bottomLeading ? 1 : -1
        let down: CGFloat = corner == .topLeading || corner == .topTrailing ? 1 : -1
        var path = Path()
        path.move(to: CGPoint(x: center.x + across * Self.armLength, y: center.y))
        path.addLine(to: center)
        path.addLine(to: CGPoint(x: center.x, y: center.y + down * Self.armLength))
        return path
    }
}

#if DEBUG
/// The screenshot harness's editor: the same generated sample movie and pose frames, so the
/// canvas renders a playing clip instead of the load-failure state.
#Preview {
    ScreenshotClipEditorHarness()
        .preferredColorScheme(.dark)
}
#endif

/// The non-visual path to the follow crop. Framing a clip is pinch, two-finger rotate and
/// drag — three gestures a VoiceOver user cannot perform, which would leave the editor's whole
/// purpose unreachable without sight. The zooms, turns and moves set the keyframe at the
/// playhead, as the gestures do; the keyframe actions step the playhead between keyframes and
/// add or remove the one at it, "Apply zoom and turn to all keyframes" gives every keyframe the
/// zoom and turn at the playhead, and Reset follow returns to the whole frame. Make crop wider and
/// Make crop taller reshape the marker about its center, as the corner handles do by touch.
private struct CropAdjustmentActions: ViewModifier {
    let viewModel: ClipEditorViewModel
    let videoSize: CGSize
    /// The settled marker on screen, and on-screen points per displayed pixel under it: what a
    /// reshape is measured from (`ClipEditorViewModel.resizeCrop`).
    let marker: CGRect
    let previewScale: CGFloat

    /// The marker stretched about its center by `factor` across or down.
    private func reshape(widthBy widthFactor: CGFloat, heightBy heightFactor: CGFloat) {
        let size = CGSize(width: marker.width * widthFactor, height: marker.height * heightFactor)
        let drawn = CGRect(
            x: marker.midX - size.width / 2, y: marker.midY - size.height / 2,
            width: size.width, height: size.height)
        viewModel.resizeCrop(from: marker, to: drawn, previewScale: previewScale)
    }

    func body(content: Content) -> some View {
        let step = CGSize(
            width: videoSize.width * CropAdjustmentStep.offsetFraction,
            height: videoSize.height * CropAdjustmentStep.offsetFraction)
        let move: (CGSize) -> Void = { viewModel.moveFollow(byDisplayedPixels: $0) }
        // Two expressions rather than one chain, which the type checker gives up on.
        let framing = content
            .accessibilityAction(named: "Zoom in") {
                viewModel.applyCropScale(CropAdjustmentStep.zoomFactor)
            }
            .accessibilityAction(named: "Zoom out") {
                viewModel.applyCropScale(1 / CropAdjustmentStep.zoomFactor)
            }
            .accessibilityAction(named: "Rotate clockwise") {
                viewModel.applyCropRotation(CropAdjustmentStep.rotationRadians)
            }
            .accessibilityAction(named: "Rotate counterclockwise") {
                viewModel.applyCropRotation(-CropAdjustmentStep.rotationRadians)
            }
            .accessibilityAction(named: "Move left") { move(CGSize(width: -step.width, height: 0)) }
            .accessibilityAction(named: "Move right") { move(CGSize(width: step.width, height: 0)) }
            .accessibilityAction(named: "Move up") { move(CGSize(width: 0, height: -step.height)) }
            .accessibilityAction(named: "Move down") { move(CGSize(width: 0, height: step.height)) }
            .accessibilityAction(named: "Previous keyframe") { viewModel.seekToKeyframe(after: false) }
            .accessibilityAction(named: "Next keyframe") { viewModel.seekToKeyframe(after: true) }
            .accessibilityAction(named: "Add keyframe") { viewModel.addKeyframeAtPlayhead() }
            .accessibilityAction(named: "Remove keyframe") {
                if let keyframe = viewModel.keyframeAtPlayhead {
                    viewModel.removeKeyframe(keyframe)
                }
            }
            .accessibilityAction(named: "Apply zoom and turn to all keyframes") {
                viewModel.applyZoomAndTurnAtPlayheadToAllKeyframes()
            }
            .accessibilityAction(named: "Reset follow") { viewModel.resetFollow() }
        return framing
            .accessibilityAction(named: "Make crop wider") {
                reshape(widthBy: CropAdjustmentStep.reshapeFactor, heightBy: 1)
            }
            .accessibilityAction(named: "Make crop taller") {
                reshape(widthBy: 1, heightBy: CropAdjustmentStep.reshapeFactor)
            }
    }
}
