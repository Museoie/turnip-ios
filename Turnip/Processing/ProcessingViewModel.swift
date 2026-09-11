import Foundation

/// The processing screen's state machine (issue #17).
///
/// Owns the pipeline `Task`: `cancel()` stops it, and the view cancels on disappear, so a
/// run never outlives its screen. Cancellation is cooperative — the sampler loop checks
/// between frames — so cancel returns immediately while the in-flight frame finishes; the
/// `CancellationError` is swallowed because the screen is already gone by then.
@MainActor
final class ProcessingViewModel: ObservableObject {
    enum State {
        case idle
        case downloading(fraction: Double)
        case processing(frame: Int, totalFrames: Int?, fraction: Double?)
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
        case .idle, .downloading, .processing:
            true
        case .succeeded, .empty, .failed:
            false
        }
    }

    private let runner: any ProcessingRunning
    private var runTask: Task<Void, Never>?
    /// Guards `runTask` against a scheduling race: the run task's trailing teardown hops to
    /// the main actor *after* `finish`/`fail` have run, so a new run started in that gap would
    /// have its handle cleared by the old run's teardown (orphaning it — `cancel()` would no
    /// longer stop it). Each lifecycle transition bumps the generation, and the teardown only
    /// clears the task when its captured generation still matches.
    private var runGeneration = 0

    init(runner: any ProcessingRunning = ProcessingPipeline()) {
        self.runner = runner
    }

    /// Starts the pipeline. Ignored while a run is in flight — the screen shows one run.
    func start(input: ProcessingInput) {
        guard runTask == nil else { return }
        runGeneration += 1
        let generation = runGeneration
        let runner = self.runner
        // Weak capture: the task must not keep the view model (and its screen) alive.
        runTask = Task { [weak self] in
            do {
                let result = try await runner.run(input: input) { progress in
                    await MainActor.run { [weak self] in self?.apply(progress) }
                }
                await MainActor.run { [weak self] in self?.finish(with: result) }
            } catch is CancellationError {
                // Cancel dismisses the screen; there is nothing to show.
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { [weak self] in self?.fail(with: message) }
            }
            await MainActor.run { [weak self] in
                if self?.runGeneration == generation {
                    self?.runTask = nil
                }
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        // Invalidate any trailing teardown still draining from the cancelled run, so it
        // cannot clear a newer run's handle.
        runGeneration += 1
    }

    /// Restarts after a failure. Ignored while a run is in flight.
    func retry(input: ProcessingInput) {
        guard !isRunning else { return }
        state = .idle
        result = nil
        isShowingClips = false
        start(input: input)
    }

    private func apply(_ progress: ProcessingProgress) {
        switch progress {
        case .downloading(let fraction):
            state = .downloading(fraction: fraction)
        case .processing(let frame, let totalFrames):
            state = .processing(frame: frame, totalFrames: totalFrames, fraction: progress.fraction)
        }
    }

    private func finish(with result: ProcessingResult) {
        if result.clips.isEmpty {
            state = .empty
        } else {
            self.result = result
            state = .succeeded
            isShowingClips = true
        }
    }

    private func fail(with message: String) {
        state = .failed(message: message)
    }
}
