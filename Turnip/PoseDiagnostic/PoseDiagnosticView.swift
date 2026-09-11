import AVFoundation
import SwiftUI

/// Empirical-test tool per docs/DESIGN.md's "first work item": run MoveNet Thunder on a real
/// tricking clip and surface per-frame confidence + keypoint count, to decide whether Thunder
/// is accurate enough or the model escalation ladder needs to fire.
///
/// Reached from Home by tapping a video tile.
struct PoseDiagnosticView: View {
    let video: SelectedVideo
    @StateObject private var viewModel = PoseDiagnosticViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Video length \(VideoDurationFormatter.string(from: video.duration))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Run diagnostic") {
                viewModel.runDiagnostic(on: video.asset)
            }
            .disabled(viewModel.isRunning)

            if viewModel.isRunning {
                ProgressView("Running pose detection…")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            List(viewModel.results) { result in
                VStack(alignment: .leading) {
                    Text("Frame \(result.frameIndex) · t=\(String(format: "%.2f", result.timestamp))s")
                        .font(.headline)
                    Text("avg confidence \(String(format: "%.2f", result.averageConfidence)) · usable \(result.usableKeypointCount)/17")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
        .padding()
        .navigationTitle("Pose diagnostic")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PoseDiagnosticView(
            video: SelectedVideo(assetIdentifier: "preview", asset: AVURLAsset(url: URL(filePath: "/dev/null")), duration: 12)
        )
    }
}
