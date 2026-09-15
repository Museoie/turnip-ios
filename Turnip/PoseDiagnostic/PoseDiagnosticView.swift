import AVFoundation
import AVKit
import SwiftUI

/// Empirical-test tool per docs/DESIGN.md's "first work item": run MoveNet Thunder on a real
/// tricking clip and surface per-frame confidence + keypoint count, to decide whether Thunder
/// is accurate enough or the model escalation ladder needs to fire.
///
/// The video plays above the per-frame list with the nearest sampled frame's keypoints drawn
/// over it, and tapping a row pauses on that frame — the numbers are only a diagnosis if they
/// can be checked against the picture they describe.
///
/// Reached from Home by tapping a video tile.
struct PoseDiagnosticView: View {
    let video: SelectedVideo
    @StateObject private var viewModel = PoseDiagnosticViewModel()

    var body: some View {
        VStack(spacing: 12) {
            playerSection

            HStack {
                Text("Video length \(VideoDurationFormatter.string(from: video.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Run diagnostic") {
                    viewModel.runDiagnostic(on: video.asset)
                }
                .disabled(viewModel.isRunning)
            }

            if viewModel.isRunning {
                ProgressView("Running pose detection…")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Text(viewModel.summary.map(PoseDiagnosticLabels.summary) ?? PoseDiagnosticLabels.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            resultList
        }
        .padding()
        .navigationTitle("Pose diagnostic")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.prepare(with: video.asset)
        }
        .onDisappear {
            viewModel.teardown()
        }
    }

    /// The player with the current frame's keypoints over it. The stack takes the displayed
    /// frame's aspect ratio so the video fills it edge to edge and the overlay's normalized
    /// coordinates land on the video, not on letterbox bars; 16:9 stands in until the size loads.
    private var playerSection: some View {
        ZStack {
            VideoPlayer(player: viewModel.player)
            if viewModel.displaySize != nil, let current = viewModel.currentResult {
                PoseOverlayView(keypoints: current.keypoints)
            }
        }
        .aspectRatio(viewModel.displaySize ?? CGSize(width: 16, height: 9), contentMode: .fit)
        .frame(maxHeight: 300)
    }

    private var resultList: some View {
        List(viewModel.results) { result in
            Button {
                viewModel.seek(to: result)
            } label: {
                VStack(alignment: .leading) {
                    Text(PoseDiagnosticLabels.rowTitle(for: result))
                        .font(.headline)
                    Text(PoseDiagnosticLabels.rowDetail(for: result))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(
                result.id == viewModel.currentResult?.id ? Color.accentColor.opacity(0.15) : nil)
        }
        .listStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        PoseDiagnosticView(
            video: SelectedVideo(
                assetIdentifier: "preview",
                asset: AVURLAsset(url: URL(filePath: "/dev/null")),
                duration: 12
            )
        )
    }
}
