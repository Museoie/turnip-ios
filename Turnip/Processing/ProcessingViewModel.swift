import Foundation

/// The processing screen's state machine.
///
/// Owns the pipeline `Task`: `cancel()` stops it and returns the screen to `.idle`, so a run
/// never outlives its screen and returning to a cancelled run starts a fresh one rather than
/// finding a progress bar with nothing behind it. Cancellation is cooperative — the sampler
/// loop checks between frames — so cancel returns immediately while the in-flight frame
/// finishes; `runGeneration` is what keeps that frame's trailing progress report from
/// repainting the screen the user just left.
@MainActor
final class ProcessingViewModel: ObservableObject {
    enum State {
        case idle
        case processing(ProcessingProgress)
        case succeeded
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var result: ProcessingResult?
    /// Drives the navigation to the success destination once a run finishes — including a
    /// run that detected zero tricks: its empty `ProcessingResult` still navigates, and Name
    /// Clips itself says "No tricks found" (`NameClipsView`).
    @Published var isShowingClips = false

    var isRunning: Bool {
        switch state {
        case .idle, .processing:
            true
        case .succeeded, .failed:
            false
        }
    }

    private let runner: any ProcessingRunning
    private let announce: AccessibilityAnnouncing
    private var runTask: Task<Void, Never>?
    /// Identifies the run each callback belongs to. A cancelled run keeps decoding its
    /// in-flight frame and reports progress afterwards; without this, that report would drive
    /// the state machine back to `.processing` behind a screen that has no run.
    private var runGeneration = 0
    /// The quarter of the run already spoken, `nil` before a run's first report. Reset with
    /// the state machine so a retry speaks its own progress from the start rather than
    /// resuming the previous attempt's position.
    private var lastAnnouncedMilestone: Int?

    init(
        runner: any ProcessingRunning = ProcessingPipeline(),
        announce: @escaping AccessibilityAnnouncing = postAccessibilityAnnouncement
    ) {
        self.runner = runner
        self.announce = announce
    }

    /// Starts the pipeline. Only a fresh view model starts: ignored unless the state is
    /// `.idle`, so re-appearing the screen (the view's `.task` fires on every appear) never
    /// re-runs a finished run. `cancel` and `retry` both reset to `.idle`, so returning to a
    /// cancelled run and retrying a failed one still flow through here.
    ///
    /// The handle is checked too, not just the state: a run that has not yet reported its
    /// first frame is still `.idle`, and a second `start` in that gap would orphan it.
    ///
    /// `people` is the person mode chosen on the screen when the user tapped to start.
    func start(video: SelectedVideo, people: PersonMode = .one) {
        guard runTask == nil, case .idle = state else { return }
        runGeneration += 1
        let generation = runGeneration
        let runner = self.runner
        // Weak capture: the task must not keep the view model (and its screen) alive.
        runTask = Task { [weak self] in
            do {
                let result = try await runner.run(video: video, people: people) { [weak self] progress in
                    guard let self else { return }
                    await MainActor.run { self.apply(progress, from: generation) }
                }
                await MainActor.run { [weak self] in self?.finish(with: result, from: generation) }
            } catch is CancellationError {
                // Cancel already returned the screen to idle; there is nothing to show.
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { [weak self] in self?.fail(with: message, from: generation) }
            }
        }
    }

    /// Goes straight to the clip list with no clips and no pose frames, leaving the video
    /// un-analyzed: the user cuts clips by hand from the list's "+" tile instead. Same guard
    /// as `start` — only an idle screen with no run in flight can skip. Lands in `.succeeded`
    /// rather than staying `.idle`: pushing the destination disappears this screen, whose
    /// `cancel()` wipes `result` and `isShowingClips` from any running state, and `.idle`
    /// counts as running.
    func skipAnalysis(video: SelectedVideo) {
        guard runTask == nil, case .idle = state else { return }
        runGeneration += 1
        result = ProcessingResult(
            detection: DetectedClips(clips: [], poseFrames: []),
            asset: video.asset,
            analysisSkipped: true)
        state = .succeeded
        isShowingClips = true
    }

    /// Stops an in-flight run and returns the screen to `.idle`. A cancel after the run has
    /// already reached a terminal state is a no-op: the view cancels on disappear, and pushing
    /// the success destination disappears this screen, so wiping `result` there would pop the
    /// destination the user is looking at.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        runGeneration += 1
        lastAnnouncedMilestone = nil
        guard isRunning else { return }
        state = .idle
        result = nil
        isShowingClips = false
    }

    /// Restarts after a failure, in the person mode the screen shows when Retry is tapped.
    func retry(video: SelectedVideo, people: PersonMode = .one) {
        guard !isRunning else { return }
        runTask?.cancel()
        runTask = nil
        runGeneration += 1
        lastAnnouncedMilestone = nil
        state = .idle
        result = nil
        isShowingClips = false
        start(video: video, people: people)
    }

    private func apply(_ progress: ProcessingProgress, from generation: Int) {
        guard generation == runGeneration else { return }
        state = .processing(progress)
        guard let spoken = ProcessingAnnouncements.progressAnnouncement(
            for: progress, lastAnnounced: lastAnnouncedMilestone)
        else { return }
        lastAnnouncedMilestone = spoken.milestone
        announce(spoken.message)
    }

    private func finish(with result: ProcessingResult, from generation: Int) {
        guard generation == runGeneration else { return }
        self.result = result
        state = .succeeded
        isShowingClips = true
    }

    private func fail(with message: String, from generation: Int) {
        guard generation == runGeneration else { return }
        state = .failed(message: message)
        announce(ProcessingAnnouncements.failureAnnouncement(message: message))
    }
}
