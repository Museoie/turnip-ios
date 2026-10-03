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
        _viewModel = StateObject(wrappedValue: ClipEditorViewModel(source: source))
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
        }
    }

    var body: some View {
        VStack(spacing: 16) {
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
        .navigationTitle("Edit clip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { backButton }
            ToolbarItem(placement: .navigationBarTrailing) { deleteButton }
        }
        .task {
            await viewModel.prepare()
        }
        .onDisappear {
            viewModel.teardown()
        }
    }

    /// Commits the current edits and closes — the back chevron's action. Runs
    /// synchronously with the tap, before `dismiss()` starts the cover's transition, so
    /// the presenting screen's state settles before the animation begins instead of
    /// racing it.
    private var backButton: some View {
        BackChevronButton(accessibilityLabel: "Back to clips") {
            onCommit(viewModel.result)
            close()
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            onDelete()
            closeAfterDelete()
        } label: {
            Text("Delete")
        }
        .accessibilityLabel("Delete clip")
    }

    /// The trimmed clip, looping, full frame with the crop area's fixed marker drawn
    /// over it — pinch/rotate/drag the video underneath to adjust what lands inside it.
    private var previewSection: some View {
        Group {
            if let overlay = viewModel.previewOverlay, overlay.videoSize.width > 0 {
                fullFramePreview(overlay: overlay)
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
        // Reports this surface's own on-screen frame (global space, the same space a
        // presenter captures a grid tile's frame in) so a Photos-style expansion
        // transition can land its flying card exactly here without duplicating this
        // view's own aspect-ratio layout math.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ClipEditorPreviewFramePreferenceKey.self,
                    value: proxy.frame(in: .global))
            }
        )
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
            // Resolution-independent: a fraction of the video's own bounds, so the
            // gesture's anchor matches `ClipExportTransform.make`'s anchor (the crop
            // rect's center) regardless of the on-screen container's point size.
            let anchor = UnitPoint(
                x: overlay.cropRect.midX / overlay.videoSize.width,
                y: overlay.cropRect.midY / overlay.videoSize.height)
            let liveScale = viewModel.cropAdjustment.scale * gestureScale
            let liveRotation = Angle(radians: viewModel.cropAdjustment.rotationRadians) + gestureRotation
            // `cropAdjustment.offset` is displayed-pixel space (`applyCropOffset`'s
            // contract) while `gestureOffset` is the in-flight drag's own screen points —
            // `* scale` converts the committed offset into the same screen-point space
            // this view renders in before the two are summed.
            let liveOffset = CGSize(
                width: viewModel.cropAdjustment.offset.width * scale + gestureOffset.width,
                height: viewModel.cropAdjustment.offset.height * scale + gestureOffset.height)
            ZStack {
                BareVideoPlayerView(player: viewModel.player)
                    .scaleEffect(liveScale, anchor: anchor)
                    .rotationEffect(liveRotation, anchor: anchor)
                    .offset(liveOffset)
                    .clipped()
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
