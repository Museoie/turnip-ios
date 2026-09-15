import AVFoundation
import AVKit
import SwiftUI

/// The pipeline progress screen (`docs/UIUX.md` § "Processing").
///
/// Pushed onto the flow's shared `NavigationStack` when a video is picked. It does *not*
/// start the pipeline on appear: the idle state shows the picked video with native
/// playback controls and a manual "Start analysis" button — black background, no title,
/// Photos-app look. Once started it shows real per-frame progress ("Analyzing frame 400
/// of 1,200"), and on success navigates to `destination` with the detected clips. Empty
/// and error states stay on this screen with a way back. Like the other pushed screens,
/// it declares no `NavigationStack` of its own.
///
/// The success destination is injected rather than hardcoded to the clip list, so
/// `Processing` never depends on `ClipList`'s view type (`ClipListView`): the screen
/// that pushes this one supplies `destination`. The destination also receives
/// `popToRoot` — the flow's "back to Home" action — so its back button can skip this
/// screen instead of stepping back through the flow.
struct ProcessingView<Destination: View>: View {
    let video: SelectedVideo
    let destination: (ProcessingResult, @escaping () -> Void) -> Destination
    /// `false` in previews, which would otherwise kick off a real pipeline run on appear.
    /// Home passes `false` too: analysis starts from the idle state's button, never
    /// automatically.
    let autostart: Bool
    /// Pops the flow's navigation stack back to Home. Threaded into the success
    /// destination so its back button returns to the start of the flow.
    let popToRoot: () -> Void

    @StateObject private var viewModel: ProcessingViewModel
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    init(
        video: SelectedVideo,
        runner: any ProcessingRunning = ProcessingPipeline(),
        autostart: Bool = true,
        popToRoot: @escaping () -> Void = {},
        destination: @escaping (ProcessingResult, @escaping () -> Void) -> Destination
    ) {
        self.video = video
        self.autostart = autostart
        self.popToRoot = popToRoot
        self.destination = destination
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(runner: runner))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                idleState
            case .processing(let progress):
                processingState(progress)
            case .empty:
                emptyState
            case .failed(let message):
                errorState(message: message)
            case .succeeded:
                // Covered by the pushed destination; only visible when navigating back here.
                Text("Analysis complete.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationBarBackButtonHidden(isAnalyzing)
        .toolbar {
            if isAnalyzing {
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
                destination(result, popToRoot)
            }
        }
        .task {
            if player == nil {
                player = AVPlayer(playerItem: AVPlayerItem(asset: video.asset))
            }
            if autostart {
                viewModel.start(video: video)
            }
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    /// Back/Cancel track the *processing* state rather than `viewModel.isRunning`: idle is
    /// this screen's resting state now (analysis starts manually), so it keeps the default
    /// back chevron to Home. `isRunning` still counts idle as running — the pipeline's
    /// tests lean on that — so it can't drive this.
    private var isAnalyzing: Bool {
        if case .processing = viewModel.state { return true }
        return false
    }

    /// The resting state: the picked video, large, with native playback controls, and a
    /// manual "Start analysis" button below it. Black background, no title — the Photos
    /// app look; the back chevron (to Home) is the only chrome.
    private var idleState: some View {
        VStack(spacing: 20) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { ProgressView() }
            }
            Text("Play the video, or start analysis when ready.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Pause the idle player before the `VideoPlayer` leaves the hierarchy:
            // nothing would call `pause()` on it afterwards, so its audio would
            // keep playing behind the progress UI and the clip list.
            Button("Start analysis") {
                player?.pause()
                viewModel.start(video: video)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
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
            destination: { result, _ in
                Text("\(result.clips.count) clips")
            }
        )
    }
}
