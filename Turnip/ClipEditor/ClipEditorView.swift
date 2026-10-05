import AVFoundation
import CoreVideo
import SwiftUI

/// The per-clip editor (`docs/UIUX.md` § "Clip Detail / Editor"): full-screen,
/// one clip at a time — the trimmed clip looping inside its full frame with the crop
/// area marked over it (pinch to zoom, rotate with two fingers, drag to reposition the
/// video under the fixed crop marker) and a scrub bar with start/end drag handles.
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
    @GestureState private var gestureScale: CGFloat = 1
    @GestureState private var gestureRotation: Angle = .zero
    @GestureState private var gestureOffset: CGSize = .zero

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
                // video surface is meant to keep a downward drag for itself.
                .ignoresSafeArea()
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            topRow
            previewSection
            resetCropButton
            TrimSliderView(viewModel: viewModel)
            Spacer(minLength: 0)
        }
        .padding()
        // Behind this view's own content rather than wrapping it, so the dismiss
        // gesture only ever sees the margins/empty space this content doesn't already
        // claim with its own gesture (the crop surface, the trim slider, the buttons)
        // — see `ClipExpansionContainer`'s doc comment for why it has to be attached
        // here rather than behind this whole view in a presenter's own hierarchy.
        .background(dismissGestureLayer)
        // No navigation bar: the bar is the stack's own view laid over this screen, so a
        // drag that starts in its band never reaches the dismiss gesture behind this
        // content. `topRow` draws the same controls as content instead, which leaves the
        // whole area above the video to that gesture — `ProcessingView` hides its bar for
        // the same reason.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            await viewModel.prepare()
        }
        .onDisappear {
            viewModel.teardown()
        }
    }

    /// The screen's own top row in place of a navigation bar (see `body`): the back chevron
    /// leading, the title centered, Delete trailing.
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

    /// The trimmed clip, looping, full frame with the crop area's fixed marker drawn
    /// over it — pinch/rotate/drag the video underneath to adjust what lands inside it.
    private var previewSection: some View {
        Group {
            if let overlay = viewModel.previewOverlay, overlay.videoSize.width > 0 {
                // Reports this surface's own on-screen frame (global space, the same space
                // a presenter captures a grid tile's frame in) so a Photos-style expansion
                // transition can land its flying card exactly here without duplicating this
                // view's own aspect-ratio layout math. Only this branch reports: the
                // loading/error placeholders below are an arbitrary 9:16 rect that doesn't
                // match the clip's real aspect ratio, and reporting it would hand the
                // expansion transition a destination to grow toward that's wrong for
                // every clip that isn't actually 9:16.
                fullFramePreview(overlay: overlay)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ClipEditorPreviewFramePreferenceKey.self,
                                value: proxy.frame(in: .global))
                        }
                    )
            } else if viewModel.failedToLoad {
                StatusStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load this clip",
                    message: "The video file couldn't be read."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Couldn't load this clip. The video file couldn't be read.")
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
    }

    /// The full frame with the crop area's fixed marker drawn over it: the dimmed
    /// surround marks what export cuts away. The video underneath carries the pinch/
    /// rotate/drag gesture — the marker rectangle itself never moves, matching what the
    /// export composes (`ClipExportTransform.make`'s `cropAdjustment`). Sized to the
    /// displayed frame's aspect ratio so the overlay maps 1:1 onto the video.
    private func fullFramePreview(overlay: (videoSize: CGSize, cropRect: CGRect)) -> some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / overlay.videoSize.width
            let hole = CGRect(
                x: overlay.cropRect.minX * scale,
                y: overlay.cropRect.minY * scale,
                width: overlay.cropRect.width * scale,
                height: overlay.cropRect.height * scale)
            ZStack {
                ClipEditorVideoSurface(
                    player: viewModel.player,
                    cropCenter: UnitPoint(
                        x: overlay.cropRect.midX / overlay.videoSize.width,
                        y: overlay.cropRect.midY / overlay.videoSize.height),
                    adjustment: viewModel.cropAdjustment,
                    pointsPerDisplayedPixel: scale,
                    gestureScale: gestureScale,
                    gestureRotation: gestureRotation,
                    gestureOffset: gestureOffset)
                // Hidden until an expansion flight's card — the same player, same
                // transform — has landed here; the marker and controls above fade in over it.
                .expansionVideoSurface()
                CropOverlayShape(hole: hole)
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                Rectangle()
                    .stroke(.white, lineWidth: 2)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(cropGesture(previewScale: scale))
        }
        .aspectRatio(overlay.videoSize, contentMode: .fit)
        .clipped()
        .accessibilityLabel("Clip preview with crop area")
        .accessibilityHint("Pinch to zoom, rotate with two fingers, or drag to reposition")
        .overlay(alignment: .bottom) { playbackControls }
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
        .allowsHitTesting(true)
    }

    /// Discards the manual crop adjustment and returns to the algorithm's own framing —
    /// replaces the old full-frame/cropped-preview toggle now that the crop area is
    /// directly editable.
    private var resetCropButton: some View {
        Button {
            viewModel.resetCropAdjustment()
        } label: {
            Label("Reset crop area", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.cropAdjustment == .identity)
    }
}

/// The video under the editor's crop marker: the player, transformed by the user's crop
/// adjustment about the crop rect's center and clipped to its own bounds. Shared by the
/// editor's preview and by `ClipExpansionContainer`'s flying card, so the card shows
/// exactly the picture the editor will show — the same player, the same transform —
/// and the cut between the two is invisible. Sized by its container to the displayed
/// frame's aspect ratio; `pointsPerDisplayedPixel` converts the adjustment's committed
/// offset (displayed-pixel space, `applyCropOffset`'s contract) into this view's own
/// points, while the in-flight gesture values are already in points.
struct ClipEditorVideoSurface: View {
    let player: AVPlayer
    /// The crop rect's center as a fraction of the video's bounds — resolution-independent,
    /// so the gesture's anchor matches `ClipExportTransform.make`'s anchor regardless of
    /// the on-screen size.
    let cropCenter: UnitPoint
    let adjustment: CropAdjustment
    let pointsPerDisplayedPixel: CGFloat
    var gestureScale: CGFloat = 1
    var gestureRotation: Angle = .zero
    var gestureOffset: CGSize = .zero
    var onReadyForDisplay: (() -> Void)?

    var body: some View {
        BareVideoPlayerView(player: player, onReadyForDisplay: onReadyForDisplay)
            .scaleEffect(adjustment.scale * gestureScale, anchor: cropCenter)
            .rotationEffect(Angle(radians: adjustment.rotationRadians) + gestureRotation, anchor: cropCenter)
            .offset(
                x: adjustment.offset.width * pointsPerDisplayedPixel + gestureOffset.width,
                y: adjustment.offset.height * pointsPerDisplayedPixel + gestureOffset.height)
            .clipped()
    }
}

/// `previewSection`'s own on-screen frame, read by a Photos-style expansion
/// transition presenting this view — see that modifier's call site above. Reduces to
/// the latest non-zero report: during the frame this view first mounts, a stale zero
/// default can still be in flight.
struct ClipEditorPreviewFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The dimmed surround with a hole at the crop rect, for the editor's crop preview.
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
