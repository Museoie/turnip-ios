import SwiftUI

/// The pipeline progress screen (issue #17; `docs/UIUX.md` § "Processing").
///
/// Pushed onto the flow's shared `NavigationStack` when a video is picked: it starts the
/// pipeline on appear, shows real per-frame progress ("Analyzing frame 400 of 1,200"), and
/// on success navigates to `destination` with the detected clips. Empty and error states
/// stay on this screen with a way back. Like `ClipListView`, it declares no
/// `NavigationStack` of its own.
///
/// The success destination is injected rather than hardcoded to the clip list: #11 is
/// still an unmerged PR, so this screen can't name its type — Home (#16) wires
/// `ProcessingView(input:) { result in ClipListView(...) }` when it lands.
struct ProcessingView<Destination: View>: View {
    let input: ProcessingInput
    let destination: (ProcessingResult) -> Destination
    /// `false` in previews, which would otherwise kick off a real pipeline run on appear.
    let autostart: Bool

    @StateObject private var viewModel: ProcessingViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        input: ProcessingInput,
        runner: any ProcessingRunning = ProcessingPipeline(),
        autostart: Bool = true,
        destination: @escaping (ProcessingResult) -> Destination
    ) {
        self.input = input
        self.autostart = autostart
        self.destination = destination
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(runner: runner))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView("Preparing…")
            case .downloading(let fraction):
                downloadState(fraction: fraction)
            case .processing(let frame, let totalFrames, let fraction):
                processingState(frame: frame, totalFrames: totalFrames, fraction: fraction)
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
                viewModel.start(input: input)
            }
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private func downloadState(fraction: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: fraction)
                .accessibilityLabel("iCloud download progress")
            Text("Downloading from iCloud…")
                .font(.headline)
            Text("The full video has to download before analysis can start.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private func processingState(frame: Int, totalFrames: Int?, fraction: Double?) -> some View {
        VStack(spacing: 16) {
            if let fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Analysis progress")
            } else {
                ProgressView()
                    .accessibilityLabel("Analyzing video")
            }
            Text(progressLabel(frame: frame, totalFrames: totalFrames))
                .font(.headline)
            Text("This runs fully on-device and can take a while for long videos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    /// "Analyzing frame 400 of 1,200" per the design doc; the total is unknown when the
    /// track reports no frame rate, so the counter stands alone.
    private func progressLabel(frame: Int, totalFrames: Int?) -> String {
        if let totalFrames {
            "Analyzing frame \(frame) of \(totalFrames)"
        } else {
            "Analyzing frame \(frame)…"
        }
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
            Button("Retry") { viewModel.retry(input: input) }
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
            input: ProcessingInput(source: .fileURL(URL(fileURLWithPath: "/nonexistent.mov"))),
            autostart: false,
            destination: { result in
                Text("\(result.clips.count) clips")
            }
        )
    }
}
