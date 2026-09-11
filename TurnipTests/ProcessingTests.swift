import AVFoundation
import XCTest
@testable import Turnip

final class ProcessingProgressTests: XCTestCase {
    func testDownloadingFractionClampsToUnitRange() {
        XCTAssertEqual(ProcessingProgress.downloading(0.5).fraction, 0.5)
        XCTAssertEqual(ProcessingProgress.downloading(1.5).fraction, 1)
        XCTAssertEqual(ProcessingProgress.downloading(-0.25).fraction, 0)
    }

    func testProcessingFractionDividesProcessedByTotal() {
        XCTAssertEqual(ProcessingProgress.processing(frame: 300, totalFrames: 1200).fraction, 0.25)
    }

    func testProcessingFractionClampsOvershoot() {
        XCTAssertEqual(ProcessingProgress.processing(frame: 1300, totalFrames: 1200).fraction, 1)
    }

    func testProcessingFractionIsNilWhenTheTotalIsUnknown() {
        XCTAssertNil(ProcessingProgress.processing(frame: 300, totalFrames: nil).fraction)
        XCTAssertNil(ProcessingProgress.processing(frame: 300, totalFrames: 0).fraction)
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
            TrickWindow(startTime: 1.15, endTime: 1.65),
        ]

        let clips = pipeline.buildClips(windows: windows, frames: frames, naturalSize: size)

        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips.map(\.window), windows)
        // The clip's crop rect is exactly the calculator's answer for the frames inside the
        // window (indices 2...8 and 12...16 at 0.1 s spacing) — this pins the wiring, not
        // the calculator's math, which its own tests own.
        let calculator = CropRectCalculator()
        let first = calculator.cropRect(for: Array(frames[2...8]), sourcePixelSize: size)
        let second = calculator.cropRect(for: Array(frames[12...16]), sourcePixelSize: size)
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
    private static var input: ProcessingInput {
        ProcessingInput(source: .fileURL(URL(fileURLWithPath: "/nonexistent.mov")))
    }

    private static var clip: ProcessedClip {
        ProcessedClip(
            window: TrickWindow(startTime: 1, endTime: 2),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
        )
    }

    func testFailingRunSurfacesTheErrorMessage() async {
        let viewModel = ProcessingViewModel(runner: ScriptedRunner(behavior: .fail(TestError.boom)))

        viewModel.start(input: Self.input)
        await Self.waitUntilNotRunning(viewModel)

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("expected the failed state, got \(viewModel.state)")
        }
        XCTAssertEqual(message, "kaput")
        XCTAssertFalse(viewModel.isShowingClips)
    }

    func testEmptyResultShowsTheEmptyState() async {
        let viewModel = ProcessingViewModel(runner: ScriptedRunner(behavior: .succeed(clips: [])))

        viewModel.start(input: Self.input)
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

        viewModel.start(input: Self.input)
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

        viewModel.start(input: Self.input)
        var sawProgress = false
        for _ in 0..<200 {
            if case .processing(let frame, let totalFrames, let fraction) = viewModel.state {
                XCTAssertEqual(frame, 42)
                XCTAssertEqual(totalFrames, 100)
                XCTAssertEqual(fraction, 0.42)
                sawProgress = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawProgress, "the progress report never reached the view model")

        viewModel.cancel()
        for _ in 0..<200 {
            if await flag.observed { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(await flag.observed, "cancelling the run did not stop the runner")
    }

    func testRetryAfterFailureRunsAgain() async {
        let runner = ScriptedRunner(behavior: .fail(TestError.boom))
        let viewModel = ProcessingViewModel(runner: runner)

        viewModel.start(input: Self.input)
        await Self.waitUntilNotRunning(viewModel)
        guard case .failed = viewModel.state else {
            return XCTFail("expected the failed state, got \(viewModel.state)")
        }

        runner.behavior = .succeed(clips: [Self.clip])
        viewModel.retry(input: Self.input)
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

        viewModel.start(input: Self.input)
        viewModel.start(input: Self.input) // second start must not replace the in-flight run
        viewModel.cancel()

        for _ in 0..<200 {
            if await flag.observed { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(await flag.observed, "the first run was replaced instead of kept")
    }

    /// Regression test for the teardown race: cancelling a run and immediately starting a
    /// new one must not orphan the new run — the old run's trailing teardown must not clear
    /// the new run's handle, or the final `cancel()` would silently stop working.
    func testCancelThenStartKeepsNewRunCancellable() async {
        let flag = CancelFlag()
        let runner = ScriptedRunner(behavior: .reportThenHang(flag))
        let viewModel = ProcessingViewModel(runner: runner)

        viewModel.start(input: Self.input)
        viewModel.cancel() // the old run's trailing teardown is still draining here
        viewModel.start(input: Self.input) // must not be orphaned by that teardown

        viewModel.cancel()
        for _ in 0..<200 {
            if await flag.observed { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(
            await flag.observed,
            "the new run was orphaned by the old run's teardown and could not be cancelled"
        )
    }

    private static func waitUntilNotRunning(_ viewModel: ProcessingViewModel) async {
        for _ in 0..<200 where viewModel.isRunning {
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

/// A scripted `ProcessingRunning`: the real pipeline needs a video file and the model, so
/// the view-model tests drive the state machine with canned behaviors instead.
private final class ScriptedRunner: ProcessingRunning, @unchecked Sendable {
    enum Behavior {
        case succeed(clips: [ProcessedClip])
        case fail(Error)
        /// Reports one progress update, then sleeps until cancelled and records it on the flag.
        case reportThenHang(CancelFlag)
    }

    /// Set once before the run in each test (or between runs for the retry test); never
    /// mutated while a run is in flight.
    var behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func run(
        input: ProcessingInput,
        onProgress: @escaping @Sendable (ProcessingProgress) async -> Void
    ) async throws -> ProcessingResult {
        switch behavior {
        case .succeed(let clips):
            return ProcessingResult(clips: clips, asset: AVAsset())
        case .fail(let error):
            throw error
        case .reportThenHang(let flag):
            await onProgress(.processing(frame: 42, totalFrames: 100))
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                await flag.noteCancelled()
                throw error
            }
            return ProcessingResult(clips: [], asset: AVAsset())
        }
    }
}
