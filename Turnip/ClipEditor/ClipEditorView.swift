import AVFoundation
import CoreVideo
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
/// screen's state while the dismiss transition is still animating is what made the
/// back chevron need repeated taps to register.
struct ClipEditorView: View {
    @StateObject private var viewModel: ClipEditorViewModel
    /// The final editor state, committed on back-navigation — no separate save step,
    /// per the design doc.
    let onCommit: (ClipEditorResult) -> Void
    /// The Delete action: removes the clip from the list entirely, distinct from
    /// keep/discard (which the list's own toggle still owns).
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
    @GestureState private var gestureScale: CGFloat = 1
    @GestureState private var gestureRotation: Angle = .zero
    @GestureState private var gestureOffset: CGSize = .zero
    /// The stage's on-screen frame (global space): the band between the header row and
    /// the bottom controls, which the crop marker is centered in. Reported by the layout
    /// placeholder in `chrome` and fixed per device — it never depends on the clip.
    @State private var stageFrame: CGRect = .zero

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

    @ViewBuilder
    private var dismissGestureLayer: some View {
        if let dismissGesture {
            Color.clear
                .contentShape(Rectangle())
                .gesture(dismissGesture)
                // Edge to edge, so the status-bar band above the top row counts too: only the
                // stage is meant to keep a downward drag for itself.
                .ignoresSafeArea()
        }
    }

    /// The crop marker's frame, in global space: one fixed rectangle of the crop rect's
    /// aspect ratio centered in the stage. Reported to a presenting `ClipExpansionContainer`
    /// as the part of the screen its flying card's window starts on.
    private var markerFrame: CGRect {
        ClipEditorStage.markerRect(in: stageFrame, aspectRatio: viewModel.targetAspectRatio)
    }

    var body: some View {
        ZStack {
            stage
            chrome
        }
        .preference(key: ClipEditorCropMarkerFramePreferenceKey.self, value: markerFrame)
        // Behind this view's own content rather than wrapping it, so the dismiss
        // gesture only ever sees the margins/empty space this content doesn't already
        // claim with its own gesture (the stage, the trim slider, the buttons)
        // — see `ClipExpansionContainer`'s doc comment for why it has to be attached
        // here rather than behind this whole view in a presenter's own hierarchy.
        .background(dismissGestureLayer)
        // No navigation bar: the bar is the stack's own view laid over this screen, so a
        // drag that starts in its band never reaches the dismiss gesture behind this
        // content. `topRow` draws the same controls as content instead, in the band the
        // bar would occupy (`ScreenHeaderBand`), which leaves the whole area above the
        // stage to that gesture — `ProcessingView` hides its bar for the same reason.
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
        VStack(spacing: 0) {
            ScreenHeaderBand { topRow }
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ClipEditorStageFramePreferenceKey.self, value: proxy.frame(in: .global))
            }
            .allowsHitTesting(false)
            // Over the placeholder, not inside it: the placeholder passes touches through,
            // and the notice has to keep its own tap-to-dismiss.
            .overlay(alignment: .top) { noHorizonNotice }
            VStack(spacing: 16) {
                autoFramingButtons
                TrimSliderView(viewModel: viewModel)
            }
            .padding()
        }
        .onPreferenceChange(ClipEditorStageFramePreferenceKey.self) { stageFrame = $0 }
    }

    /// The screen's own top row in place of a navigation bar (see `body`): the back chevron
    /// leading, the title centered, Delete trailing — the same arrangement, at the same
    /// positions, as the clip list's titled bar this screen flies open from.
    private var topRow: some View {
        ZStack {
            Text("Edit clip")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("clip-editor-title")
            HStack {
                backButton
                Spacer()
                deleteButton
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
    }

    private var deleteButton: some View {
        let button = Button(role: .destructive) {
            onDelete()
            closeAfterDelete()
        } label: {
            Text("Delete")
        }
        .accessibilityLabel("Delete clip")
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
            let band = stageFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let placement = viewModel.previewOverlay.flatMap {
                ClipEditorStage.videoPlacement(videoSize: $0.videoSize, cropRect: $0.cropRect, marker: marker)
            }
            ZStack {
                ClipEditorVideoSurface(
                    player: viewModel.player,
                    geometry: viewModel.previewOverlay,
                    marker: marker,
                    adjustment: viewModel.cropAdjustment,
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
                }
                Rectangle()
                    .stroke(.white, lineWidth: 2)
                    .frame(width: marker.width, height: marker.height)
                    .position(x: marker.midX, y: marker.midY)
                    .allowsHitTesting(false)
                    // Lets a UI test read the marker's frame, to check a presenting
                    // container's card lands its picture exactly here. Not a control:
                    // the gesture surface below carries the stage's label and hint.
                    .accessibilityIdentifier("crop-marker")
                loadingState(in: marker)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: band.width, height: band.height)
                    .position(x: band.midX, y: band.midY)
                    .gesture(cropGesture(previewScale: placement?.pointsPerDisplayedPixel ?? 0))
                    .accessibilityLabel("Clip preview with crop area")
                    .accessibilityHint("Pinch to zoom, rotate with two fingers, or drag to reposition")
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

    /// The pinch (zoom), two-finger rotate, and one-finger drag gestures, composed so
    /// all three can run at once. Each commits its cumulative delta into the view model
    /// on end; `@GestureState` supplies the live in-flight delta for rendering.
    /// `previewScale` (on-screen points per displayed pixel) only matters to the drag —
    /// scale and rotation are unit-agnostic.
    private func cropGesture(previewScale: CGFloat) -> some Gesture {
        SimultaneousGesture(
            SimultaneousGesture(magnificationGesture, rotationGesture),
            dragGesture(previewScale: previewScale))
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($gestureScale) { value, state, _ in state = value }
            .onEnded { value in viewModel.applyCropScale(value) }
    }

    private var rotationGesture: some Gesture {
        RotationGesture()
            .updating($gestureRotation) { value, state, _ in state = value }
            .onEnded { value in viewModel.applyCropRotation(value.radians) }
    }

    private func dragGesture(previewScale: CGFloat) -> some Gesture {
        DragGesture()
            .updating($gestureOffset) { value, state, _ in state = value.translation }
            .onEnded { value in viewModel.applyCropOffset(value.translation, previewScale: previewScale) }
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
    /// its icon while it runs.
    private var autoFramingButtons: some View {
        HStack(spacing: 12) {
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
    }

    /// Auto rotate's answer when the window shows no horizon the detector can find: the
    /// rotation stays as it was, and the notice says why.
    @ViewBuilder
    private var noHorizonNotice: some View {
        if viewModel.isShowingNoHorizonNotice {
            GlassNoticeView(message: "No horizon found", isPresented: $viewModel.isShowingNoHorizonNotice)
                .padding(.top, 8)
                .accessibilityIdentifier("no-horizon-notice")
        }
    }
}

/// The video under the editor's crop marker: the player laid out at
/// `ClipEditorStage.videoPlacement`'s frame — the whole displayed frame, placed so the
/// crop rect fills `marker` — and transformed by the user's crop adjustment about the
/// crop rect's center. Never clipped: whatever the adjustment pushes outside the frame's
/// own rect stays visible, the way the export and the tile show it. Shared by the editor's
/// stage and by `ClipExpansionContainer`'s flying card, so the card shows exactly the
/// picture the editor will show — the same player, the same placement — and the cut
/// between the two is invisible. Lays out to whatever size it is given; `marker` is in
/// that space. Until `geometry` is known the player sits hidden at the marker: it has to
/// exist for its first frame to decode (`onReadyForDisplay`), but has no right place yet.
struct ClipEditorVideoSurface: View {
    let player: AVPlayer
    /// `ClipEditorViewModel.previewOverlay`: the displayed frame's size and the crop rect in
    /// it, both in displayed pixels. `nil` until media info has loaded.
    let geometry: (videoSize: CGSize, cropRect: CGRect)?
    let marker: CGRect
    let adjustment: CropAdjustment
    var gestureScale: CGFloat = 1
    var gestureRotation: Angle = .zero
    var gestureOffset: CGSize = .zero
    var onReadyForDisplay: (() -> Void)?

    var body: some View {
        let placement = geometry.flatMap {
            ClipEditorStage.videoPlacement(videoSize: $0.videoSize, cropRect: $0.cropRect, marker: marker)
        }
        let frame = placement?.frame ?? marker
        // The committed offset is in displayed pixels (`applyCropOffset`'s contract); the
        // in-flight gesture offset is already in points.
        let pointsPerDisplayedPixel = placement?.pointsPerDisplayedPixel ?? 0
        // The crop rect's center as a fraction of the frame — resolution-independent, so the
        // gesture's anchor matches `ClipExportTransform.make`'s anchor at any on-screen size.
        let cropCenter = geometry.map {
            UnitPoint(x: $0.cropRect.midX / $0.videoSize.width, y: $0.cropRect.midY / $0.videoSize.height)
        } ?? .center
        BareVideoPlayerView(player: player, onReadyForDisplay: onReadyForDisplay)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(adjustment.scale * gestureScale, anchor: cropCenter)
            .rotationEffect(Angle(radians: adjustment.rotationRadians) + gestureRotation, anchor: cropCenter)
            .offset(
                x: adjustment.offset.width * pointsPerDisplayedPixel + gestureOffset.width,
                y: adjustment.offset.height * pointsPerDisplayedPixel + gestureOffset.height)
            .position(x: frame.midX, y: frame.midY)
            .opacity(placement == nil ? 0 : 1)
    }
}

/// The stage's own on-screen frame (global space), climbing from the layout placeholder in
/// `ClipEditorView.chrome` to the view that derives the marker from it. Reduces to the
/// latest non-zero report: the placeholder's siblings in the chrome column contribute the
/// zero default, and the last of them would otherwise win the reduction.
private struct ClipEditorStageFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The crop marker's on-screen frame (global space), read by a Photos-style expansion
/// transition presenting this view: the part of the screen the tile's picture lands on,
/// so the flying card's window starts there. Reduces to the latest non-zero report: during
/// the frame this view first mounts, a stale zero default can still be in flight.
struct ClipEditorCropMarkerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The surround with a hole at the crop marker, for the editor's stage.
private struct CropOverlayShape: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(hole)
        return path
    }
}

#Preview {
    NavigationStack {
        ClipEditorView(
            source: ClipEditorSource(
                window: TrickWindow(startTime: 2, endTime: 5),
                cropRect: NormalizedRect(minX: 0.25, maxX: 0.75, minY: 0.25, maxY: 0.75),
                asset: AVURLAsset(url: makeClipEditorPreviewAsset()),
                poseFrames: []),
            onCommit: { _ in },
            onDelete: {})
    }
    .preferredColorScheme(.dark)
}

/// Writes a tiny generated sample movie for the `#Preview` above — six seconds of
/// solid-color H.264 frames — so the canvas renders the editor instead of the
/// load-failure state. (`/dev/null` isn't media, so `prepare()` took the failing path
/// and the preview showed "Couldn't load this clip", which reads as a broken screen.)
///
/// A bundled fixture .mov would be larger and opaque; generating follows the same
/// `AVAssetWriter` pattern as the `VideoFrameSamplerTests` video fixture. Synchronous
/// because `#Preview` bodies can't await: the write is a few hundred local frames, so
/// the bounded spin below finishes in well under a second. If generation fails on the
/// preview host, the partial file is deleted and the preview degrades to the
/// load-failure state instead of crashing.
private func makeClipEditorPreviewAsset() -> URL {
    let url = URL.temporaryDirectory.appending(path: "ClipEditorPreview-\(UUID().uuidString).mov")
    do {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 320
        let height = 568
        let fps: Int32 = 30
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input), writer.startWriting() else { throw PreviewAssetError.setupFailed }
        writer.add(input)
        writer.startSession(atSourceTime: .zero)
        try writePreviewFrames(writer: writer, input: input, adaptor: adaptor, fps: fps)
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        // The completion handler runs off the main thread, so waiting here can't deadlock.
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw PreviewAssetError.finishFailed }
        return url
    } catch {
        try? FileManager.default.removeItem(at: url)
        return URL(fileURLWithPath: "/dev/null")
    }
}

/// Appends six seconds of solid-color frames to the preview asset writer, extracted
/// from `makeClipEditorPreviewAsset()` so it stays within the function-body length limit.
private func writePreviewFrames(
    writer: AVAssetWriter,
    input: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    fps: Int32
) throws {
    for frame in 0..<(6 * Int(fps)) {
        // Bounded on writer status: if the writer fails mid-write,
        // `isReadyForMoreMediaData` never becomes true, and without the status check
        // the loop would spin with no cause.
        var spins = 0
        while !input.isReadyForMoreMediaData, writer.status == .writing, spins < 500 {
            Thread.sleep(forTimeInterval: 0.002)
            spins += 1
        }
        guard let pool = adaptor.pixelBufferPool else { throw PreviewAssetError.setupFailed }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw PreviewAssetError.setupFailed
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
            // Vary the fill per frame so the encoder emits real (non-skipped) frames.
            memset(base, Int32(frame % 255), bytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let time = CMTime(value: CMTimeValue(frame), timescale: fps)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw PreviewAssetError.appendFailed
        }
    }
}

private enum PreviewAssetError: Error {
    case setupFailed, appendFailed, finishFailed
}
