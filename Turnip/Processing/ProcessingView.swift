import AVFoundation
import SwiftUI

/// The pipeline progress screen (`docs/UIUX.md` § "Processing").
///
/// Pushed onto the flow's shared `NavigationStack` when a video is picked: it starts the
/// pipeline on appear, shows real per-frame progress ("Analyzing frame 400 of 1,200"), and
/// on success navigates to `destination` with the detected clips. Empty and error states
/// stay on this screen with a way back. Like the other pushed screens, it declares no
/// `NavigationStack` of its own.
///
/// The success destination is injected rather than hardcoded to the clip list, whose type
/// does not exist on `main` yet: Home wires
/// `ProcessingView(video:) { result in ClipListView(...) }` once it lands.
struct ProcessingView<Destination: View>: View {
    let video: SelectedVideo
    let destination: (ProcessingResult) -> Destination
    /// `false` in previews, which would otherwise kick off a real pipeline run on appear.
    let autostart: Bool

    @StateObject private var viewModel: ProcessingViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        video: SelectedVideo,
        runner: any ProcessingRunning = ProcessingPipeline(),
        autostart: Bool = true,
        destination: @escaping (ProcessingResult) -> Destination
    ) {
        self.video = video
        self.autostart = autostart
        self.destination = destination
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(runner: runner))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView("Preparing…")
            case .processing(let progress):
                processingState(progress)
            case .succeeded:
                // Covered by the pushed destination; only visible when navigating back here.
                Text("Analysis complete.")
                    .foregroundStyle(.secondary)
            case .empty:
                emptyState
            case .failed(let message):
                errorState(message: message)
            }
        }
        .navigationTitle("Analyzing video")
        .navigationBarBackButtonHidden(viewModel.isRunning)
        .toolbar {
            if viewModel.isRunning {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancel()
                        dismiss()
                    }
                }
            }
        }
        .navigationDestination(isPresented: $viewModel.isShowingClips) {
            if let result = viewModel.result {
                destination(result)
            }
        }
        .task {
            if autostart {
                viewModel.start(video: video)
            }
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private func processingState(_ progress: ProcessingProgress) -> some View {
        VStack(spacing: 16) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Analysis progress")
            } else {
                ProgressView()
                    .accessibilityLabel("Analyzing video")
            }
            Text(progress.label)
                .font(.headline)
            Text("This runs fully on-device and can take a while for long videos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No tricks found")
                .font(.title2)
            Text("The whole video was analyzed but nothing moved like a trick. "
                + "Try a clip with bigger, faster movement.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Back to Home") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding()
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Couldn't analyze this video")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { viewModel.retry(video: video) }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            Button("Back to Home", role: .cancel) { dismiss() }
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        ProcessingView(
            video: SelectedVideo(
                assetIdentifier: "preview",
                asset: AVURLAsset(url: URL(fileURLWithPath: "/nonexistent.mov")),
                duration: 12
            ),
            autostart: false,
            destination: { result in
                Text("\(result.clips.count) clips")
            }
        )
    }
}
