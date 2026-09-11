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
        case empty
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var result: ProcessingResult?
    /// Drives the navigation to the success destination once a run finds clips.
    @Published var isShowingClips = false

    var isRunning: Bool {
        switch state {
        case .idle, .processing:
            true
        case .succeeded, .empty, .failed:
            false
        }
    }

    private let runner: any ProcessingRunning
    private var runTask: Task<Void, Never>?
    /// Identifies the run each callback belongs to. A cancelled run keeps decoding its
    /// in-flight frame and reports progress afterwards; without this, that report would drive
    /// the state machine back to `.processing` behind a screen that has no run.
    private var runGeneration = 0

    init(runner: any ProcessingRunning = ProcessingPipeline()) {
        self.runner = runner
    }

    /// Starts the pipeline. Only a fresh view model starts: ignored unless the state is
    /// `.idle`, so re-appearing the screen (the view's `.task` fires on every appear) never
    /// re-runs a finished run. `cancel` and `retry` both reset to `.idle`, so returning to a
    /// cancelled run and retrying a failed one still flow through here.
    ///
    /// The handle is checked too, not just the state: a run that has not yet reported its
    /// first frame is still `.idle`, and a second `start` in that gap would orphan it.
    func start(video: SelectedVideo) {
        guard runTask == nil, case .idle = state else { return }
        runGeneration += 1
        let generation = runGeneration
        let runner = self.runner
        // Weak capture: the task must not keep the view model (and its screen) alive.
        runTask = Task { [weak self] in
            do {
                let result = try await runner.run(video: video) { progress in
                    await MainActor.run { [weak self] in self?.apply(progress, from: generation) }
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

    /// Stops an in-flight run and returns the screen to `.idle`. A cancel after the run has
    /// already reached a terminal state is a no-op: the view cancels on disappear, and pushing
    /// the success destination disappears this screen, so wiping `result` there would pop the
    /// destination the user is looking at.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        runGeneration += 1
        guard isRunning else { return }
        state = .idle
        result = nil
        isShowingClips = false
    }

    /// Restarts after a failure or an empty result.
    func retry(video: SelectedVideo) {
        guard !isRunning else { return }
        runTask?.cancel()
        runTask = nil
        runGeneration += 1
        state = .idle
        result = nil
        isShowingClips = false
        start(video: video)
    }

    private func apply(_ progress: ProcessingProgress, from generation: Int) {
        guard generation == runGeneration else { return }
        state = .processing(progress)
    }

    private func finish(with result: ProcessingResult, from generation: Int) {
        guard generation == runGeneration else { return }
        if result.clips.isEmpty {
            state = .empty
        } else {
            self.result = result
            state = .succeeded
            isShowingClips = true
        }
    }

    private func fail(with message: String, from generation: Int) {
        guard generation == runGeneration else { return }
        state = .failed(message: message)
    }
}
