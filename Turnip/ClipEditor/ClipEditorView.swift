import AVFoundation
import AVKit
import CoreVideo
import SwiftUI

/// The per-clip editor (`docs/UIUX.md` § "Clip Detail / Editor"): full-screen,
/// one clip at a time — the trimmed clip looping with its live crop rect drawn over it, a
/// scrub bar with start/end drag handles, and the keep/discard toggle.
///
/// Back-navigation commits the edits: `onCommit` fires with the final state when the view
/// disappears — no separate save step, per the design doc.
struct ClipEditorView: View {
    @StateObject private var viewModel: ClipEditorViewModel
    /// The final editor state, committed when the view disappears. Note: `onDisappear`
    /// fires for *any* disappearance — including a sheet presented over the editor —
    /// so this view must not present sheets, or a sheet would commit a half-edited
    /// draft and tear down the preview mid-edit.
    let onCommit: (ClipEditorResult) -> Void

    init(source: ClipEditorSource, onCommit: @escaping (ClipEditorResult) -> Void) {
        _viewModel = StateObject(wrappedValue: ClipEditorViewModel(source: source))
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: 16) {
            previewSection
            TrimSliderView(viewModel: viewModel)
            keepToggle
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Edit clip")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.prepare()
        }
        .onDisappear {
            onCommit(viewModel.result)
            viewModel.teardown()
        }
    }

    /// The trimmed clip, looping, with the live crop rect drawn over the displayed frame:
    /// the dimmed surround is what the export cuts away. Sized to the displayed frame's
    /// aspect ratio so the overlay maps 1:1 onto the video.
    private var previewSection: some View {
        Group {
            if let overlay = viewModel.previewOverlay, overlay.videoSize.width > 0 {
                GeometryReader { proxy in
                    let scale = proxy.size.width / overlay.videoSize.width
                    let hole = CGRect(
                        x: overlay.cropRect.minX * scale,
                        y: overlay.cropRect.minY * scale,
                        width: overlay.cropRect.width * scale,
                        height: overlay.cropRect.height * scale)
                    ZStack {
                        VideoPlayer(player: viewModel.player)
                        CropOverlayShape(hole: hole)
                            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        Rectangle()
                            .stroke(.white, lineWidth: 2)
                            .frame(width: hole.width, height: hole.height)
                            .position(x: hole.midX, y: hole.midY)
                    }
                }
                .aspectRatio(overlay.videoSize, contentMode: .fit)
                .accessibilityLabel("Clip preview with crop area")
            } else if viewModel.failedToLoad {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't load this clip")
                        .font(.headline)
                    Text("The video file couldn't be read.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Couldn't load this clip. The video file couldn't be read.")
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
    }

    private var keepToggle: some View {
        Button {
            viewModel.toggleKeep()
        } label: {
            Label(
                viewModel.isKept ? "Clip kept" : "Clip discarded",
                systemImage: viewModel.isKept ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(viewModel.isKept ? "Discard clip" : "Keep clip")
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
                isKept: true,
                asset: AVURLAsset(url: makeClipEditorPreviewAsset()),
                poseFrames: []),
            onCommit: { _ in })
    }
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
