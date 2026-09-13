import AVFoundation
import Foundation
import XCTest
@testable import Turnip

final class ProcessingProgressTests: XCTestCase {
    func testFractionDividesProcessedByTotal() {
        XCTAssertEqual(ProcessingProgress(frame: 300, totalFrames: 1200).fraction, 0.25)
    }

    func testFractionClampsOvershoot() {
        XCTAssertEqual(ProcessingProgress(frame: 1300, totalFrames: 1200).fraction, 1)
    }

    func testFractionIsNilWhenTheTotalIsUnknown() {
        XCTAssertNil(ProcessingProgress(frame: 300, totalFrames: nil).fraction)
        XCTAssertNil(ProcessingProgress(frame: 300, totalFrames: 0).fraction)
    }

    func testLabelCountsAgainstTheTotal() {
        XCTAssertEqual(
            ProcessingProgress(frame: 400, totalFrames: 1200).label,
            "Analyzing frame 400 of 1200"
        )
    }

    func testLabelDropsTheTotalWhenItIsUnknown() {
        XCTAssertEqual(ProcessingProgress(frame: 400, totalFrames: nil).label, "Analyzing frame 400…")
    }

    /// The denominator is an estimate from an average frame rate, so variable-frame-rate
    /// capture can overrun it; "frame 412 of 400" must never render.
    func testLabelDropsTheTotalOnceTheCountOverrunsIt() {
        XCTAssertEqual(ProcessingProgress(frame: 412, totalFrames: 400).label, "Analyzing frame 412…")
        XCTAssertEqual(
            ProcessingProgress(frame: 400, totalFrames: 400).label,
            "Analyzing frame 400 of 400"
        )
    }
}

final class SampledFrameCountTests: XCTestCase {
    /// The sampler keeps frame 0 and then every 3rd, so a 10-frame track yields frames
    /// 0/3/6/9 — four, not three. Integer division would under-count the denominator and the
    /// counter would run past it.
    func testCountRoundsUpTheWayTheSamplerDoes() {
        XCTAssertEqual(ProcessingPipeline.sampledFrameCount(trackFrameCount: 9, stride: 3), 3)
        XCTAssertEqual(ProcessingPipeline.sampledFrameCount(trackFrameCount: 10, stride: 3), 4)
        XCTAssertEqual(ProcessingPipeline.sampledFrameCount(trackFrameCount: 11, stride: 3), 4)
        XCTAssertEqual(ProcessingPipeline.sampledFrameCount(trackFrameCount: 12, stride: 3), 4)
    }

    func testCountIsAtLeastOne() {
        XCTAssertEqual(ProcessingPipeline.sampledFrameCount(trackFrameCount: 0, stride: 3), 1)
        XCTAssertEqual(ProcessingPipeline.sampledFrameCount(trackFrameCount: 1, stride: 3), 1)
    }

    func testCountUsesTheGivenStride() {
        // At 60 fps the stride is 6: a 61-frame track yields frames 0/6/…/60 — 11, not 21.
        XCTAssertEqual(ProcessingPipeline.sampledFrameCount(trackFrameCount: 61, stride: 6), 11)
    }
}

final class ProgressReportClockTests: XCTestCase {
    func testFirstReportIsAlwaysAllowed() async {
        let allowed = await Self.decisions(at: [100])
        XCTAssertEqual(allowed, [true])
    }

    func testReportsWithinTheIntervalAreDropped() async {
        let allowed = await Self.decisions(at: [100, 100.05, 100.09])
        XCTAssertEqual(allowed, [true, false, false])
    }

    /// A dropped report must not restart the interval, or a steady stream of frames arriving
    /// faster than the interval would suppress every report after the first.
    ///
    /// The allowed times clear the interval by a comfortable margin rather than landing on it:
    /// `100.1 - 100` is `0.0999…` in binary floating point, so a fixture sitting exactly on the
    /// boundary tests the representation rather than the rule. Measuring from the last *call*
    /// instead would drop index 2 as well, which is what makes this sequence discriminate.
    func testTheIntervalIsMeasuredFromTheLastReportNotTheLastCall() async {
        let allowed = await Self.decisions(at: [100, 100.05, 100.12, 100.15, 100.25])
        XCTAssertEqual(allowed, [true, false, true, false, true])
    }

    /// Each decision is collected and asserted as a sequence: the interesting property is
    /// which calls in a run are allowed, and `XCTAssert*` takes an autoclosure that cannot
    /// carry an `await` anyway.
    private static func decisions(at times: [TimeInterval]) async -> [Bool] {
        let clock = ProgressReportClock(minimumInterval: 0.1)
        var allowed: [Bool] = []
        for time in times {
            allowed.append(await clock.shouldReport(at: time))
        }
        return allowed
    }
}

final class ProcessingPipelineClipTests: XCTestCase {
    private let size = CGSize(width: 1080, height: 1920)

    /// 20 frames at 0.1 s intervals with confident hips, so the crop calculator resolves.
    private var frames: [PoseFrameResult] {
        PoseFixture.frames(hipXPositions: PoseFixture.slide(
            quietFrames: 2, from: 0.2, perFrame: 0.05, movingFrames: 16, tailFrames: 2
        ))
    }

    func testBuildClipsAssignsFramesByTimestampAndComputesCropRects() {
        let pipeline = ProcessingPipeline()
        let windows = [
            TrickWindow(startTime: 0.15, endTime: 0.85),
            TrickWindow(startTime: 1.15, endTime: 1.65)
        ]

        let clips = pipeline.buildClips(windows: windows, frames: frames, naturalSize: size)

        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips.map(\.window), windows)
        // The clip's crop rect is exactly the calculator's answer for the frames inside the
        // window (indices 2...8 and 12...16 at 0.1 s spacing) — this pins the wiring, not
        // the calculator's math, which its own tests own.
        let calculator = CropRectCalculator()
        let first = calculator.cropRect(for: Array(frames[2...8]), renderedPixelSize: size)
        let second = calculator.cropRect(for: Array(frames[12...16]), renderedPixelSize: size)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(clips[0].cropRect, first)
        XCTAssertEqual(clips[1].cropRect, second)
    }

    func testBuildClipsFallsBackToFullFrameWhenNoKeypointsAreUsable() {
        // Every keypoint sits below the confidence threshold, so the calculator returns nil.
        let frames = (0..<10).map { PoseFixture.frame(index: $0, hip: nil) }

        let clips = ProcessingPipeline().buildClips(
            windows: [TrickWindow(startTime: 0, endTime: 1)],
            frames: frames,
            naturalSize: size
        )

        // The trick was still detected from the motion signal — it stays visible for triage
        // with a full-frame crop instead of being dropped.
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].cropRect, NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
    }

    func testBuildClipsWithNoWindowsReturnsNoClips() {
        let clips = ProcessingPipeline().buildClips(windows: [], frames: frames, naturalSize: size)
        XCTAssertTrue(clips.isEmpty)
    }
}

@MainActor
final class ProcessingViewModelTests: XCTestCase {
    private static var video: SelectedVideo {
        SelectedVideo(
            assetIdentifier: "test",
            asset: AVURLAsset(url: URL(fileURLWithPath: "/nonexistent.mov")),
            duration: 10
        )
    }

    private static var clip: ProcessedClip {
        ProcessedClip(
            window: TrickWindow(startTime: 1, endTime: 2),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
        )
    }

    func testFailingRunSurfacesTheErrorMessage() async {
        let viewModel = ProcessingViewModel(runner: ScriptedRunner(behavior: .fail(TestError.boom)))

        viewModel.start(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("expected the failed state, got \(viewModel.state)")
        }
        XCTAssertEqual(message, "kaput")
        XCTAssertFalse(viewModel.isShowingClips)
    }

    func testEmptyResultShowsTheEmptyState() async {
        let viewModel = ProcessingViewModel(runner: ScriptedRunner(behavior: .succeed(clips: [])))

        viewModel.start(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)

        guard case .empty = viewModel.state else {
            return XCTFail("expected the empty state, got \(viewModel.state)")
        }
        XCTAssertFalse(viewModel.isShowingClips)
    }

    func testSuccessfulRunNavigatesToTheClips() async {
        let viewModel = ProcessingViewModel(
            runner: ScriptedRunner(behavior: .succeed(clips: [Self.clip]))
        )

        viewModel.start(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)

        guard case .succeeded = viewModel.state else {
            return XCTFail("expected the succeeded state, got \(viewModel.state)")
        }
        XCTAssertEqual(viewModel.result?.clips, [Self.clip])
        XCTAssertTrue(viewModel.isShowingClips)
    }

    func testProgressReachesTheViewAndCancelStopsTheRun() async {
        let flag = CancelFlag()
        let viewModel = ProcessingViewModel(
            runner: ScriptedRunner(behavior: .reportThenHang(flag))
        )

        viewModel.start(video: Self.video)
        await Self.waitUntilProcessing(viewModel)
        guard case .processing(let progress) = viewModel.state else {
            return XCTFail("the progress report never reached the view model")
        }
        XCTAssertEqual(progress.frame, 42)
        XCTAssertEqual(progress.totalFrames, 100)
        XCTAssertEqual(progress.fraction, 0.42)

        viewModel.cancel()
        await Self.waitUntil { await flag.observed }
        let observed = await flag.observed
        XCTAssertTrue(observed, "cancelling the run did not stop the runner")
    }

    /// Cancelling mid-run has to leave a screen a user can come back to. The view cancels on
    /// disappear and starts on appear, so a state left at its last running value would render
    /// a live progress bar over a view model with no run, and `start` would refuse to restart.
    func testCancelMidRunReturnsToIdleAndAllowsARestart() async {
        let first = CancelFlag()
        let runner = ScriptedRunner(behavior: .reportThenHang(first))
        let viewModel = ProcessingViewModel(runner: runner)

        viewModel.start(video: Self.video)
        await Self.waitUntilProcessing(viewModel)

        viewModel.cancel()
        guard case .idle = viewModel.state else {
            return XCTFail("expected idle after cancel, got \(viewModel.state)")
        }
        XCTAssertNil(viewModel.result)
        XCTAssertFalse(viewModel.isShowingClips)
        await Self.waitUntil { await first.observed }

        runner.behavior = .succeed(clips: [Self.clip])
        viewModel.start(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)

        guard case .succeeded = viewModel.state else {
            return XCTFail("the screen did not restart after a cancel, got \(viewModel.state)")
        }
    }

    /// A cancelled run keeps decoding its in-flight frame and reports progress afterwards.
    /// That report must not drive the state machine back to `.processing`, which would strand
    /// the screen exactly the way leaving the state untouched on cancel does.
    func testLateProgressFromACancelledRunCannotRepaintTheScreen() async {
        let cancelled = ProgressRelay()
        let restarted = ProgressRelay()
        let runner = ScriptedRunner(behavior: .relayProgress(cancelled))
        let viewModel = ProcessingViewModel(runner: runner)

        viewModel.start(video: Self.video)
        await Self.waitUntil { await cancelled.isReady }

        viewModel.cancel()
        await cancelled.report(ProcessingProgress(frame: 412, totalFrames: 1200))
        guard case .idle = viewModel.state else {
            return XCTFail("a cancelled run's late progress repainted the screen: \(viewModel.state)")
        }

        // And the screen still restarts, with the new run's reports landing.
        runner.behavior = .relayProgress(restarted)
        viewModel.start(video: Self.video)
        await Self.waitUntil { await restarted.isReady }
        await restarted.report(ProcessingProgress(frame: 7, totalFrames: 100))

        guard case .processing(let progress) = viewModel.state else {
            return XCTFail("the restarted run never reached the screen: \(viewModel.state)")
        }
        XCTAssertEqual(progress.frame, 7)
        viewModel.cancel()
    }

    /// Cancel is also what `onDisappear` calls when the success destination is pushed, so it
    /// must not wipe the result the pushed screen is rendering.
    func testCancelAfterSuccessKeepsTheResult() async {
        let viewModel = ProcessingViewModel(
            runner: ScriptedRunner(behavior: .succeed(clips: [Self.clip]))
        )

        viewModel.start(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)
        viewModel.cancel()

        guard case .succeeded = viewModel.state else {
            return XCTFail("cancel discarded a finished run, got \(viewModel.state)")
        }
        XCTAssertEqual(viewModel.result?.clips, [Self.clip])
        XCTAssertTrue(viewModel.isShowingClips)
    }

    func testRetryAfterFailureRunsAgain() async {
        let runner = ScriptedRunner(behavior: .fail(TestError.boom))
        let viewModel = ProcessingViewModel(runner: runner)

        viewModel.start(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)
        guard case .failed = viewModel.state else {
            return XCTFail("expected the failed state, got \(viewModel.state)")
        }

        runner.behavior = .succeed(clips: [Self.clip])
        viewModel.retry(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)

        guard case .succeeded = viewModel.state else {
            return XCTFail("expected the succeeded state after retry, got \(viewModel.state)")
        }
        XCTAssertTrue(viewModel.isShowingClips)
    }

    func testStartWhileRunningIsIgnored() async {
        let flag = CancelFlag()
        let viewModel = ProcessingViewModel(
            runner: ScriptedRunner(behavior: .reportThenHang(flag))
        )

        viewModel.start(video: Self.video)
        viewModel.start(video: Self.video) // second start must not replace the in-flight run
        viewModel.cancel()

        await Self.waitUntil { await flag.observed }
        let observed = await flag.observed
        XCTAssertTrue(observed, "the first run was replaced instead of kept")
    }

    /// The view's `.task` fires on every appear, so navigating back to a finished run must not
    /// re-run the pipeline over it.
    func testStartAfterTerminalStateIsIgnored() async {
        let runner = ScriptedRunner(behavior: .fail(TestError.boom))
        let viewModel = ProcessingViewModel(runner: runner)

        viewModel.start(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)
        guard case .failed = viewModel.state else {
            return XCTFail("expected the failed state, got \(viewModel.state)")
        }

        runner.behavior = .succeed(clips: [Self.clip])
        viewModel.start(video: Self.video)
        await Self.waitUntilNotRunning(viewModel)

        guard case .failed = viewModel.state else {
            return XCTFail("re-appearing re-ran a finished run, got \(viewModel.state)")
        }
        XCTAssertNil(viewModel.result)
    }

    private static func waitUntilNotRunning(_ viewModel: ProcessingViewModel) async {
        await waitUntil { !viewModel.isRunning }
    }

    private static func waitUntilProcessing(_ viewModel: ProcessingViewModel) async {
        await waitUntil {
            if case .processing = viewModel.state { return true }
            return false
        }
    }

    private static func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum TestError: LocalizedError {
    case boom

    var errorDescription: String? { "kaput" }
}

private actor CancelFlag {
    private(set) var observed = false

    func noteCancelled() {
        observed = true
    }
}

/// Hands the run's `onProgress` closure back to the test, so a report can be fired at a
/// chosen moment — after a cancel, say — instead of racing the runner.
private actor ProgressRelay {
    private var onProgress: (@Sendable (ProcessingProgress) async -> Void)?

    var isReady: Bool { onProgress != nil }

    func capture(_ onProgress: @escaping @Sendable (ProcessingProgress) async -> Void) {
        self.onProgress = onProgress
    }

    func report(_ progress: ProcessingProgress) async {
        await onProgress?(progress)
    }
}

/// A scripted `ProcessingRunning`: the real pipeline needs a video file and the model, so
/// the view-model tests drive the state machine with canned behaviors instead.
private final class ScriptedRunner: ProcessingRunning, @unchecked Sendable {
    enum Behavior {
        case succeed(clips: [ProcessedClip])
        case fail(Error)
        /// Reports one progress update, then sleeps until cancelled and records it on the flag.
        case reportThenHang(CancelFlag)
        /// Hands `onProgress` to the relay and sleeps, so the test drives the reporting.
        case relayProgress(ProgressRelay)
    }

    /// Tests swap this between runs, sometimes while the previous run is still draining its
    /// cancellation, so it is read once per run under a lock rather than left to race.
    var behavior: Behavior {
        get { lock.lock(); defer { lock.unlock() }; return storedBehavior }
        set { lock.lock(); storedBehavior = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var storedBehavior: Behavior

    init(behavior: Behavior) {
        self.storedBehavior = behavior
    }

    func run(
        video: SelectedVideo,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        switch behavior {
        case .succeed(let clips):
            return ProcessingResult(clips: clips, asset: video.asset)
        case .fail(let error):
            throw error
        case .reportThenHang(let flag):
            await onProgress(ProcessingProgress(frame: 42, totalFrames: 100))
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                await flag.noteCancelled()
                throw error
            }
            return ProcessingResult(clips: [], asset: video.asset)
        case .relayProgress(let relay):
            await relay.capture(onProgress)
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return ProcessingResult(clips: [], asset: video.asset)
        }
    }
}
