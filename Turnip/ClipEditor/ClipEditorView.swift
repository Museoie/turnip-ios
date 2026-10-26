import AVFoundation
import SwiftUI

/// The per-clip editor (`docs/UIUX.md` § "Clip Detail / Editor"): full-screen,
/// one clip at a time — the trimmed clip looping under a crop marker that is one fixed
/// rectangle on screen, with the video laid out so the clip's crop rect fills it and the
/// rest of the frame showing frosted around it, edge to edge (pinch to zoom, rotate with
/// two fingers, drag to reposition the video under the marker), the Auto crop and Auto
/// rotate buttons that fit the video under the marker for the user, plus a scrub bar
/// with start/end drag handles.
///
/// Back-navigation and Delete both close the editor via the toolbar's own actions —
/// `onCommit`/`onDelete` fire synchronously from those taps, before the enclosing
/// presentation dismisses, rather than from `onDisappear`: mutating the presenting
/// screen's state while the dismiss transition is still animating would race the
/// dismiss and swallow the back chevron's tap.
struct ClipEditorView: View {
    @StateObject private var viewModel: ClipEditorViewModel
    /// The final editor state, committed on back-navigation — no separate save step,
    /// per the design doc.
    let onCommit: (ClipEditorResult) -> Void
    /// The Delete action: removes the clip from the list entirely, the same as its
    /// tile's trash button.
    let onDelete: () -> Void
    /// Intercepts the back button's close instead of calling `dismiss()` directly, so
    /// a presenter can animate its own reverse transition before the cover actually
    /// goes away. `nil` (the default) falls back to `dismiss()`, which keeps
    /// `ScreenshotHarness` and this file's own `#Preview` working unchanged.
    var onRequestClose: (() -> Void)?
    /// Intercepts the Delete button's close the same way, but separately from
    /// `onRequestClose`: a presenter that flies its reverse transition back to the
    /// tile's on-screen frame (`ClipExpansionContainer`) can't reuse that same flight
    /// for Delete, since deleting the item changes what's in that slot. Falls back to
    /// `onRequestClose`, then `dismiss()`, so callers that don't need the distinction
    /// don't have to supply both.
    var onRequestDeleteClose: (() -> Void)?
    /// A presenter's own swipe-to-dismiss gesture, planted behind this view's content
    /// (see `ClipExpansionContainer`'s doc comment for why it has to live here rather
    /// than behind this view in the presenter's own hierarchy) — `nil` for callers
    /// that don't need it.
    var dismissGesture: AnyGesture<DragGesture.Value>?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.expansionHasLanded) private var expansionHasLanded
    /// The crop gestures' in-flight deltas, drawn on top of the committed adjustment until
    /// each gesture ends and commits into the view model (`CropGestureSurface`).
    @State private var gestureScale: CGFloat = 1
    @State private var gestureRotation: Angle = .zero
    @State private var gestureOffset: CGSize = .zero
    /// Set when a pinch or turn reports during the gesture the drag is part of, in Follow:
    /// the drag then sets no keyframe, so a two-finger gesture never leaves one behind.
    /// Cleared as the first finger of the next gesture lands.
    @State private var isFollowDragDropped = false
    /// Where the layout placeholder in `chrome` sits (global space), and whether the follow
    /// lane was in the layout it was measured in: the stage band of the mode it was measured
    /// in, from which both modes' bands are derived (`stillStage`, `followStage`). Fixed per
    /// device — it never depends on the clip.
    @State private var stageMeasurement = ClipEditorStageMeasurement()

    init(
        source: ClipEditorSource,
        onCommit: @escaping (ClipEditorResult) -> Void,
        onDelete: @escaping () -> Void,
        onRequestClose: (() -> Void)? = nil,
        onRequestDeleteClose: (() -> Void)? = nil,
        dismissGesture: AnyGesture<DragGesture.Value>? = nil
    ) {
        self.init(
            viewModel: ClipEditorViewModel(source: source),
            onCommit: onCommit,
            onDelete: onDelete,
            onRequestClose: onRequestClose,
            onRequestDeleteClose: onRequestDeleteClose,
            dismissGesture: dismissGesture)
    }

    /// Renders a view model the presenter owns — `ClipExpansionContainer` keeps the same
    /// player on screen in its flying card, so the editor and the card show the same
    /// frame at the instant one replaces the other.
    init(
        viewModel: ClipEditorViewModel,
        onCommit: @escaping (ClipEditorResult) -> Void,
        onDelete: @escaping () -> Void,
        onRequestClose: (() -> Void)? = nil,
        onRequestDeleteClose: (() -> Void)? = nil,
        dismissGesture: AnyGesture<DragGesture.Value>? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onCommit = onCommit
        self.onDelete = onDelete
        self.onRequestClose = onRequestClose
        self.onRequestDeleteClose = onRequestDeleteClose
        self.dismissGesture = dismissGesture
    }

    private func close() {
        if let onRequestClose {
            onRequestClose()
        } else {
            dismiss()
        }
    }

    private func closeAfterDelete() {
        if let onRequestDeleteClose {
            onRequestDeleteClose()
        } else {
            close()
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

    /// The crop marker's frame, in global space: one fixed rectangle of the crop rect's
    /// aspect ratio centered in the stage, the same for every clip in the same framing mode —
    /// Follow's is shorter by the lane. Reported to a presenting `ClipExpansionContainer` as
    /// the part of the screen its flying card's window starts on.
    private var markerFrame: CGRect {
        viewModel.framingMode == .follow ? followMarker : stillMarker
    }

    private var stillMarker: CGRect {
        ClipEditorStage.markerRect(in: stillStage, aspectRatio: viewModel.targetAspectRatio)
    }

    private var followMarker: CGRect {
        ClipEditorStage.markerRect(in: followStage, aspectRatio: viewModel.targetAspectRatio)
    }

    /// The band between the header row and the bottom controls in the active mode, where the
    /// crop gestures are taken.
    private var stageFrame: CGRect {
        viewModel.framingMode == .follow ? followStage : stillStage
    }

    /// The vertical space the follow lane takes from the stage: its own height and the gap
    /// above the trim timeline.
    private static let laneSlot = FollowLaneView.height + laneSpacing
    private static let laneSpacing: CGFloat = 4

    private var stillStage: CGRect {
        var frame = stageMeasurement.frame
        if stageMeasurement.showsLane { frame.size.height += Self.laneSlot }
        return frame
    }

    private var followStage: CGRect {
        var frame = stageMeasurement.frame
        if !stageMeasurement.showsLane { frame.size.height = max(frame.height - Self.laneSlot, 0) }
        return frame
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
        let showsLane = viewModel.framingMode == .follow
        return VStack(spacing: 0) {
            ScreenHeaderBand { topRow }
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ClipEditorStageFramePreferenceKey.self,
                    value: ClipEditorStageMeasurement(frame: proxy.frame(in: .global), showsLane: showsLane))
            }
            .allowsHitTesting(false)
            // Over the placeholder, not inside it: the placeholder passes touches through,
            // and the notice has to keep its own tap-to-dismiss.
            .overlay(alignment: .top) { notices }
            VStack(spacing: 16) {
                autoFramingButtons
                VStack(spacing: Self.laneSpacing) {
                    if showsLane {
                        FollowLaneView(viewModel: viewModel)
                            .transition(.opacity)
                    }
                    TrimSliderView(viewModel: viewModel)
                }
            }
            .padding()
        }
        .onPreferenceChange(ClipEditorStageFramePreferenceKey.self) { stageMeasurement = $0 }
    }

    /// The screen's own top row in place of a navigation bar (see `body`): the back chevron
    /// leading, the Still | Follow switch in the title's slot, Delete trailing — the
    /// chevron and Delete at the same positions as the clip list's titled bar this screen
    /// flies open from. The title stays as the screen's VoiceOver header, drawn clear.
    private var topRow: some View {
        ZStack {
            Text("Edit clip")
                .font(.headline)
                .foregroundStyle(.clear)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("clip-editor-title")
            framingSwitch
            HStack {
                backButton
                Spacer()
                deleteButton
            }
        }
    }

    /// The two framing modes, named both ways so it reads as a choice of mode rather than an
    /// effect switched on and off. Waits for media info, as the crop buttons do.
    private var framingSwitch: some View {
        Picker("Framing", selection: Binding(
            get: { viewModel.framingMode },
            set: { viewModel.setFramingMode($0) })) {
            Text("Still").tag(FramingMode.still)
            Text("Follow").tag(FramingMode.follow)
        }
        .pickerStyle(.segmented)
        .frame(width: 168)
        .disabled(viewModel.previewOverlay == nil)
        .accessibilityIdentifier("framing-mode-switch")
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

    private var deleteButton: some View {
        let button = Button(role: .destructive) {
            onDelete()
            closeAfterDelete()
        } label: {
            Text("Delete")
        }
        .accessibilityLabel("Delete clip")
        .accessibilityIdentifier("clip-editor-delete")
        return Group {
            if #available(iOS 26.0, *) {
                button.buttonStyle(.glass)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }

    /// The crop stage, edge to edge under the chrome: the video laid out so its crop rect
    /// fills the fixed marker (`ClipEditorStage`), the frosted surround marking what export
    /// cuts away, the marker's outline, and — over the stage's own band only — the pinch/
    /// rotate/drag gesture. The video and the overlays take no touches themselves: the
    /// header band and the bottom controls' margins stay with the dismiss gesture behind
    /// this view, and the playback pill sits on top of the gesture surface.
    private var stage: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let marker = markerFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let layoutMarker = stillMarker.offsetBy(dx: -origin.x, dy: -origin.y)
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
                    layoutMarker: layoutMarker,
                    framing: viewModel.framing,
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
                    // the crop stays sharp. Not drawn while an expansion flight or Delete's
                    // fade has this view under partial opacity, where a material can't blur
                    // and would render the frame behind it sharp: the flying card shows the
                    // crop alone, and the frosted frame around it appears with the landing.
                    CropOverlayShape(hole: marker)
                        .fill(.thinMaterial, style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    // The marker's outline comes and goes with the frost, in the same frame,
                    // rather than cross-fading with the rest of the chrome: on a close the
                    // outline would otherwise outlive the frost around the bare crop.
                    Rectangle()
                        .stroke(.white, lineWidth: 2)
                        .frame(width: marker.width, height: marker.height)
                        .position(x: marker.midX, y: marker.midY)
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
                    .accessibilityElement()
                    .accessibilityLabel("Clip preview with crop area")
                    .accessibilityValue(viewModel.cropAdjustmentDescription)
                    .accessibilityHint("Pinch to zoom, rotate with two fingers, or drag to reposition")
                    .accessibilityIdentifier("clip-editor-crop-surface")
                    .modifier(CropAdjustmentActions(
                        viewModel: viewModel, framingMode: viewModel.framingMode,
                        videoSize: viewModel.previewOverlay?.videoSize ?? .zero))
                playbackControls
                    .frame(width: marker.width, height: marker.height, alignment: .bottom)
                    .position(x: marker.midX, y: marker.midY)
            }
        }
        .ignoresSafeArea()
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
    /// once. Each draws its live delta over the committed adjustment while the fingers move,
    /// then commits it into the view model as they lift, in the same update, so the picture
    /// doesn't move at the hand-over; a cancelled gesture leaves nothing behind.
    /// `previewScale` (on-screen points per displayed pixel) only matters to the drag —
    /// scale and rotation are unit-agnostic.
    ///
    /// In Follow a drag places the video at the playhead's moment instead of moving it for the
    /// whole clip: touch-down pauses, and the drag sets or moves a keyframe there as it lifts
    /// (`ClipEditorViewModel.moveFollow`), unless a pinch or turn reported during it.
    private func cropGestureSurface(previewScale: CGFloat) -> some View {
        CropGestureSurface(
            onDrag: { handleDrag($0, previewScale: previewScale) },
            onPinch: handlePinch,
            onRotate: handleRotate,
            onTouchDown: {
                isFollowDragDropped = false
                viewModel.beginFollowTouch()
            })
    }

    private func handleDrag(_ phase: CropGestureSurface.Phase<CGSize>, previewScale: CGFloat) {
        let follows = viewModel.framingMode == .follow
        switch phase {
        case .changed(let translation):
            if follows {
                // In Follow the move rides the pan, with each frame, so the keyframe set as the
                // finger lifts lands on the very picture on screen.
                viewModel.previewFollowDrag(isFollowDragDropped ? .zero : translation, previewScale: previewScale)
            } else {
                gestureOffset = translation
            }
        case .ended(let translation):
            if !follows {
                viewModel.applyCropOffset(translation, previewScale: previewScale)
            } else if !isFollowDragDropped {
                viewModel.applyFollowDrag(translation, previewScale: previewScale)
            } else {
                viewModel.previewFollowDrag(.zero, previewScale: previewScale)
            }
            gestureOffset = .zero
        case .cancelled:
            viewModel.previewFollowDrag(.zero, previewScale: previewScale)
            gestureOffset = .zero
        }
    }

    private func handlePinch(_ phase: CropGestureSurface.Phase<CGFloat>) {
        switch phase {
        case .changed(let scale):
            dropFollowDrag()
            gestureScale = scale
        case .ended(let scale):
            viewModel.applyCropScale(scale)
            gestureScale = 1
        case .cancelled:
            gestureScale = 1
        }
    }

    private func handleRotate(_ phase: CropGestureSurface.Phase<Double>) {
        switch phase {
        case .changed(let radians):
            dropFollowDrag()
            gestureRotation = .radians(radians)
        case .ended(let radians):
            viewModel.applyCropRotation(radians)
            gestureRotation = .zero
        case .cancelled:
            gestureRotation = .zero
        }
    }

    /// In Follow, a pinch or turn during a drag drops the drag's keyframe and takes its live
    /// offset off the picture, so the preview never shows a move that won't be kept.
    private func dropFollowDrag() {
        guard viewModel.framingMode == .follow, !isFollowDragDropped else { return }
        isFollowDragDropped = true
        gestureOffset = .zero
        viewModel.previewFollowDrag(.zero, previewScale: 1)
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

    /// The two automatic fits, side by side above the trim slider: Auto crop frames every
    /// located keypoint in the window inside the marker at the current rotation, Auto
    /// rotate levels the clip by its roll track or its horizon. Each is a toggle: once its
    /// fit is on screen the same button reads "Reset crop" / "Reset rotate" and returns to
    /// the original video — the whole frame, unturned — independently of the other; a manual pinch, turn or drag
    /// returns both to offering their fit (`ClipEditorViewModel.isAutoCropApplied` /
    /// `isAutoRotateApplied`). Both wait for media info — before it there is no stage geometry
    /// to fit and no window to sample — and Auto rotate shows its detection in place of
    /// its icon while it runs. A clip without pose analysis (added by hand) has nothing for
    /// Auto crop to fit, so its crop button is Reset crop alone: disabled while the framing
    /// is the whole source video, enabled once a pinch or drag has moved it.
    private var autoFramingButtons: some View {
        HStack(spacing: 12) {
            if viewModel.framingMode == .follow {
                followButton
            } else if viewModel.supportsAutoCrop {
                Button {
                    if viewModel.isAutoCropApplied {
                        viewModel.resetCrop()
                    } else {
                        viewModel.autoCrop()
                    }
                } label: {
                    if viewModel.isAutoCropApplied {
                        Label("Reset crop", systemImage: "arrow.uturn.backward")
                    } else {
                        Label("Auto crop", systemImage: "crop")
                    }
                }
                .accessibilityIdentifier("auto-crop-button")
            } else {
                Button {
                    viewModel.resetCrop()
                } label: {
                    Label("Reset crop", systemImage: "arrow.uturn.backward")
                }
                .disabled(!viewModel.isCropAdjusted)
                .accessibilityIdentifier("reset-crop-button")
            }
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
        .animation(nil, value: viewModel.isAutoCropApplied)
        .animation(nil, value: viewModel.isAutoRotateApplied)
        .animation(nil, value: viewModel.isAutoFollowApplied)
        .animation(nil, value: viewModel.framingMode)
    }

    /// Follow mode's counterpart of the crop button: Auto follow ↔ Reset follow, with Auto
    /// crop's toggle rules. A clip without pose analysis has Reset follow alone, enabled once
    /// a pinch has moved its framing off the whole frame.
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
/// crop rect fills the marker — and transformed by the active framing about the crop rect's
/// center: Still's zoom, turn and offset, or Follow's zoom and turn about a center the pan
/// moves through the clip (`EditorPlayerView`). Never clipped: whatever the framing pushes
/// outside the frame's own rect stays visible, the way the export and the tile show it.
/// Shared by the editor's stage and by `ClipExpansionContainer`'s flying card, so the card
/// shows exactly the picture the editor will show — the same player, the same placement —
/// and the cut between the two is invisible. Lays out to whatever size it is given; `marker`
/// is in that space. Until `geometry` is known the player sits hidden at the marker: it has
/// to exist for its first frame to decode (`onReadyForDisplay`), but has no right place yet.
///
/// `layoutMarker` is the marker the video is laid out from, when that differs from the one the
/// crop shows in: the editor lays the video out from Still's marker in both modes and scales
/// the whole picture onto Follow's shorter one, so a mode switch animates as a transform — a
/// player view's frame doesn't animate.
struct ClipEditorVideoSurface: View {
    let frames: PreviewFrames
    /// The source track's geometry (`ClipEditorViewModel.trackGeometry`).
    let track: VideoTrackGeometry?
    /// `ClipEditorViewModel.previewOverlay`: the displayed frame's size and the crop rect in
    /// it, both in displayed pixels. `nil` until media info has loaded.
    let geometry: (videoSize: CGSize, cropRect: CGRect)?
    let marker: CGRect
    var layoutMarker: CGRect?
    let framing: EditorFraming
    /// Follow's pan (`ClipEditorViewModel.previewPan`).
    let pan: PreviewPanBlend
    var gestureScale: CGFloat = 1
    var gestureRotation: Angle = .zero
    var gestureOffset: CGSize = .zero
    var onReadyForDisplay: (() -> Void)?

    var body: some View {
        let base = layoutMarker ?? marker
        let placement = geometry.flatMap {
            ClipEditorStage.videoPlacement(videoSize: $0.videoSize, cropRect: $0.cropRect, marker: base)
        }
        let frame = placement?.frame ?? base
        // The committed offset is in displayed pixels (`applyCropOffset`'s contract).
        let pointsPerDisplayedPixel = placement?.pointsPerDisplayedPixel ?? 0
        // The crop rect's center as a fraction of the frame — resolution-independent, so the
        // gesture's anchor matches `ClipExportTransform.make`'s anchor at any on-screen size.
        let cropCenter = geometry.map {
            UnitPoint(x: $0.cropRect.midX / $0.videoSize.width, y: $0.cropRect.midY / $0.videoSize.height)
        } ?? .center
        let markerScale = base.width > 0 ? marker.width / base.width : 1
        let adjustment = framing.adjustment
        EditorPlayerView(frames: frames, track: track, pan: pan, onReadyForDisplay: onReadyForDisplay)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(adjustment.scale * gestureScale, anchor: cropCenter)
            .rotationEffect(Angle(radians: adjustment.rotationRadians) + gestureRotation, anchor: cropCenter)
            .offset(
                x: adjustment.offset.width * pointsPerDisplayedPixel,
                y: adjustment.offset.height * pointsPerDisplayedPixel)
            .position(x: frame.midX, y: frame.midY)
            // Onto the marker the crop shows in: about the space's origin, then across, so the
            // layout marker's center lands on the marker's.
            .scaleEffect(markerScale, anchor: .topLeading)
            .offset(
                x: marker.midX - base.midX * markerScale + gestureOffset.width,
                y: marker.midY - base.midY * markerScale + gestureOffset.height)
            .opacity(placement == nil ? 0 : 1)
    }
}

/// The stage placeholder's on-screen frame (global space), and whether the follow lane was
/// laid out with it — the lane takes its height from the stage.
struct ClipEditorStageMeasurement: Equatable {
    var frame: CGRect = .zero
    var showsLane = false
}

/// `ClipEditorStageMeasurement`, climbing from the layout placeholder in
/// `ClipEditorView.chrome` to the view that derives the markers from it. Reduces to the
/// latest non-zero report: the placeholder's siblings in the chrome column contribute the
/// zero default, and the last of them would otherwise win the reduction.
private struct ClipEditorStageFramePreferenceKey: PreferenceKey {
    static let defaultValue = ClipEditorStageMeasurement()

    static func reduce(value: inout ClipEditorStageMeasurement, nextValue: () -> ClipEditorStageMeasurement) {
        let next = nextValue()
        if next.frame != .zero {
            value = next
        }
    }
}

/// The crop marker's on-screen frame (global space), read by a Photos-style expansion
/// transition presenting this view: the part of the screen the tile's picture lands on,
/// so the flying card's window starts there. Reduces to the latest non-zero report: during
/// the frame this view first mounts, a stale zero default can still be in flight.
struct ClipEditorCropMarkerFramePreferenceKey: NonZeroFramePreferenceKey {}

/// The surround with a hole at the crop marker, for the editor's stage. The hole animates, so
/// the frost follows the marker through a mode switch.
private struct CropOverlayShape: Shape {
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
        set {
            hole = CGRect(
                x: newValue.first.first, y: newValue.first.second,
                width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(hole)
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

/// The non-visual path to the crop adjustment. Framing a clip is pinch, two-finger rotate and
/// drag — three gestures a VoiceOver user cannot perform, which would leave the editor's whole
/// purpose unreachable without sight. Each action drives the same view-model call the matching
/// gesture commits, so the two paths cannot diverge.
///
/// In Follow the moves set or move the keyframe at the playhead, as a drag does there, and
/// the keyframe actions step the playhead between keyframes and add or remove the one at it;
/// Reset follow stands in for Reset crop.
private struct CropAdjustmentActions: ViewModifier {
    let viewModel: ClipEditorViewModel
    let framingMode: FramingMode
    let videoSize: CGSize

    @ViewBuilder
    func body(content: Content) -> some View {
        let step = CGSize(
            width: videoSize.width * CropAdjustmentStep.offsetFraction,
            height: videoSize.height * CropAdjustmentStep.offsetFraction)
        let follows = framingMode == .follow
        let move: (CGSize) -> Void = follows
            ? { viewModel.moveFollow(byDisplayedPixels: $0) }
            : { viewModel.offsetCrop(byDisplayedPixels: $0) }
        let framed = content
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
        if follows {
            framed
                .accessibilityAction(named: "Previous keyframe") { viewModel.seekToKeyframe(after: false) }
                .accessibilityAction(named: "Next keyframe") { viewModel.seekToKeyframe(after: true) }
                .accessibilityAction(named: "Add keyframe") { viewModel.addKeyframeAtPlayhead() }
                .accessibilityAction(named: "Remove keyframe") {
                    if let keyframe = viewModel.keyframeAtPlayhead {
                        viewModel.removeKeyframe(keyframe)
                    }
                }
                .accessibilityAction(named: "Reset follow") { viewModel.resetFollow() }
        } else {
            framed.accessibilityAction(named: "Reset crop") { viewModel.resetCrop() }
        }
    }
}
