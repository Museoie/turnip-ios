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
/// The success destination is injected rather than hardcoded to the clip list, so
/// `Processing` never depends on `ClipList`'s view type (`ClipListView`): the screen
/// that pushes this one supplies `destination`.
struct ProcessingView<Destination: View>: View {
    let video: SelectedVideo
    let destination: (ProcessingResult) -> Destination
    /// `false` in previews, which would otherwise kick off a real pipeline run on appear.
    let autostart: Bool

    @StateObject private var viewModel: ProcessingViewModel
    @Environment(\.dismiss) private var dismiss
    /// The last announced phase: the `.processing` case updates with every progress
    /// frame, so the announcement keys on the phase (the state case ignoring its
    /// payload), not on the raw state — or "Analyzing video" would repeat
    /// continuously through the whole run.
    @State private var announcedPhase: AnnouncementPhase?

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
                    .accessibilityIdentifier("processing-cancel")
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
        .onChange(of: viewModel.state) { newState in
            // `.idle` arms the next run's announcement: without this, cancelling
            // and restarting in the same screen instance would keep the stale
            // phase and swallow the next "Analyzing video".
            if case .idle = newState {
                announcedPhase = nil
                return
            }
            // VoiceOver users can't see the screen change state behind the progress
            // bar, so each transition gets a spoken announcement. Gated on
            // VoiceOver running: unprompted speech when VoiceOver is off would be
            // the app talking through the speaker at nobody.
            guard UIAccessibility.isVoiceOverRunning,
                  let phase = AnnouncementPhase(state: newState),
                  announcedPhase != phase
            else { return }
            announcedPhase = phase
            UIAccessibility.post(notification: .announcement, argument: phase.announcement)
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
                .accessibilityIdentifier("processing-back-home")
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
                .accessibilityIdentifier("processing-retry")
            Button("Back to Home", role: .cancel) { dismiss() }
                .accessibilityIdentifier("processing-back-home")
        }
        .padding()
    }
}

/// The processing screen's announceable phases, for the VoiceOver state-transition
/// announcement (`ProcessingView`). Ignores the `.processing` progress payload so the
/// announcement fires once per true transition instead of once per progress frame.
private enum AnnouncementPhase: Equatable {
    case analyzing
    case succeeded
    case empty
    case failed(message: String)

    init?(state: ProcessingViewModel.State) {
        switch state {
        case .idle:
            return nil
        case .processing:
            self = .analyzing
        case .succeeded:
            self = .succeeded
        case .empty:
            self = .empty
        case .failed(let message):
            self = .failed(message: message)
        }
    }

    var announcement: String {
        switch self {
        case .analyzing:
            return String(localized: "Analyzing video")
        case .succeeded:
            return String(localized: "Analysis complete")
        case .empty:
            return String(localized: "No tricks found")
        case .failed(let message):
            return String(localized: "Couldn't analyze this video. \(message)")
        }
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
