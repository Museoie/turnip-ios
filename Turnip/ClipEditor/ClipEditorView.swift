import AVFoundation
import AVKit
import SwiftUI

/// The per-clip editor (`docs/UIUX.md` § "Clip Detail / Editor"): full-screen,
/// one clip at a time — the trimmed clip looping with its live crop rect drawn over it, a
/// scrub bar with start/end drag handles, and the keep/discard toggle.
///
/// Back-navigation commits the edits: `onCommit` fires with the final state when the view
/// disappears — no separate save step, per the design doc.
struct ClipEditorView: View {
    @StateObject private var viewModel: ClipEditorViewModel
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
            if let overlay = viewModel.previewOverlay {
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
        .accessibilityLabel("Clip preview with crop area")
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
                asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                poseFrames: []),
            onCommit: { _ in })
    }
}
