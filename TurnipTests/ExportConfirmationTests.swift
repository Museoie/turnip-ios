import AVFoundation
import XCTest
@testable import Turnip

@MainActor
final class ExportConfirmationViewModelTests: XCTestCase {
    private let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)

    private func item(start: TimeInterval = 2, end: TimeInterval = 5) -> ExportConfirmationItem {
        ExportConfirmationItem(
            window: TrickWindow(startTime: start, endTime: end), cropRect: fullFrame)
    }

    private static func exportSuccesses(_ count: Int) -> [Result<URL, Error>] {
        (0..<count).map { _ in
            .success(URL(fileURLWithPath: "/tmp/fake-export.mp4"))
        }
    }

    private static func waitUntilFinished(_ viewModel: ExportConfirmationViewModel) async {
        for _ in 0..<200 where !viewModel.isFinished {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Waits until the clip's phase is exactly `.exporting(fraction: 1.0)` — the last
    /// progress tick the fake reports before it blocks — so the assertion below can't
    /// observe the earlier 0.5 tick.
    private static func waitForFullExportProgress(
        _ viewModel: ExportConfirmationViewModel, index: Int = 0
    ) async {
        for _ in 0..<200 {
            if viewModel.clips[index].phase == .exporting(fraction: 1.0) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func waitForPhase(
        _ viewModel: ExportConfirmationViewModel,
        _ phase: ExportConfirmationViewModel.Phase,
        index: Int = 0
    ) async {
        for _ in 0..<200 {
            if viewModel.clips[index].phase == phase { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Scripted fake for the export/save seam: per-step outcomes consumed in order, a
    /// record of every call, and a one-shot gate the test arms to observe a mid-run phase
    /// deterministically.
    fileprivate actor FakeExport {
        var exportCalls: [(window: TrickWindow, cropRect: NormalizedRect)] = []
        var savedURLs: [URL] = []
        var directoryExistedAtCall: [Bool] = []
        /// The directory each export was handed, in call order — the seam a test
        /// reads to tell "one scratch directory per screen" from "one per run".
        var directoriesAtCall: [URL] = []
        var exportResults: [Result<URL, Error>]
        var saveResults: [Result<Void, Error>]
        /// Fractions the fake reports through the progress handler, in order.
        var progressFractions: [Double] = [0.5, 1.0]
        /// When true, the next export stashes its progress handler instead of
        /// reporting fractions, so the test can invoke it after the run has
        /// moved past `.exporting` (a stale tick).
        var stashProgressHandler = false
        var stashedProgressHandlers: [@Sendable (Double) -> Void] = []
        var gateNextExport = false
        /// Export call indices (0-based) to park. A set rather than the one-shot
        /// `gateNextExport` flag so a test can park a later call without having to
        /// arm the gate mid-run, which races the call it means to park.
        var gatedExportCalls: Set<Int> = []
        var gateNextSave = false
        /// Parked gates in arrival order. A FIFO, not a single slot: tests park more
        /// than one export at a time, and a single slot lets the second park
        /// overwrite the first — deallocating an unresumed continuation is a fatal
        /// error that crashes the test host.
        private var gates: [CheckedContinuation<Void, Never>] = []

        init(
            exportResults: [Result<URL, Error>] = [],
            saveResults: [Result<Void, Error>] = []
        ) {
            self.exportResults = exportResults
            self.saveResults = saveResults
        }

        func export(
            _ window: TrickWindow,
            _ cropRect: NormalizedRect,
            _ asset: AVAsset,
            _ directory: URL,
            _ progress: @escaping @Sendable (Double) -> Void
        ) async throws -> URL {
            let callIndex = exportCalls.count
            exportCalls.append((window, cropRect))
            directoriesAtCall.append(directory)
            directoryExistedAtCall.append(
                FileManager.default.fileExists(atPath: directory.path))
            if stashProgressHandler {
                stashProgressHandler = false
                stashedProgressHandlers.append(progress)
            } else {
                for fraction in progressFractions {
                    progress(fraction)
                }
            }
            if gateNextExport || gatedExportCalls.contains(callIndex) {
                gateNextExport = false
                gatedExportCalls.remove(callIndex)
                await withCheckedContinuation { gates.append($0) }
            }
            guard !exportResults.isEmpty else {
                return URL(fileURLWithPath: "/tmp/fake-export.mp4")
            }
            return try exportResults.removeFirst().get()
        }

        func save(_ url: URL) async throws {
            savedURLs.append(url)
            if gateNextSave {
                gateNextSave = false
                await withCheckedContinuation { gates.append($0) }
            }
            guard !saveResults.isEmpty else { return }
            try saveResults.removeFirst().get()
        }

        /// Resumes the earliest parked export/save. FIFO so the order is
        /// deterministic no matter which task reaches its gate first.
        func openGate() {
            guard !gates.isEmpty else { return }
            gates.removeFirst().resume()
        }
    }

    private func viewModel(
        items: [ExportConfirmationItem],
        fake: FakeExport,
        makeDirectory: (@Sendable () -> URL)? = nil
    ) -> ExportConfirmationViewModel {
        ExportConfirmationViewModel(
            items: items,
            // AVURLAsset over /dev/null rather than a bare AVAsset(): the bare
            // initializer aborts the test host ("freed pointer was not the last
            // allocation") while the harness's identical AVURLAsset form runs
            // clean (see ScreenshotHarness). The fakes never read the asset.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            exportClip: { window, cropRect, asset, directory, progress in
                try await fake.export(window, cropRect, asset, directory, progress)
            },
            saveToPhotos: { url in try await fake.save(url) },
            makeDirectory: makeDirectory ?? defaultExportDirectory)
    }

    func testExportsEveryClipInOrderAndSummarizes() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(3))
        let items = [item(start: 2, end: 5), item(start: 9, end: 11.5), item(start: 20, end: 22)]
        let viewModel = viewModel(items: items, fake: fake)

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips.map(\.phase), [.saved, .saved, .saved])
        XCTAssertEqual(viewModel.summaryText, "3 of 3 clips saved to Photos")
        XCTAssertTrue(viewModel.failures.isEmpty)
        let windows = (await fake.exportCalls).map(\.window)
        XCTAssertEqual(windows, items.map(\.window))
        let savedURLs = await fake.savedURLs
        XCTAssertEqual(savedURLs.count, 3)
    }

    func testExportFailureFailsTheClipAndContinues() async {
        let fake = FakeExport(exportResults: [
            .success(URL(fileURLWithPath: "/tmp/a.mp4")),
            .failure(ExportConfirmationError.exportFailed(reason: "window past end of video")),
            .success(URL(fileURLWithPath: "/tmp/c.mp4"))
        ])
        let viewModel = viewModel(
            items: [item(start: 2, end: 5), item(start: 9, end: 11.5), item(start: 20, end: 22)],
            fake: fake)

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips[0].phase, .saved)
        XCTAssertEqual(
            viewModel.clips[1].phase,
            .failed(reason: "Export failed — window past end of video"))
        XCTAssertEqual(viewModel.clips[2].phase, .saved)
        XCTAssertEqual(viewModel.summaryText, "2 of 3 clips saved to Photos")
        XCTAssertEqual(viewModel.failures.count, 1)
        XCTAssertEqual(viewModel.failures.first?.title, "Clip 2 · 2.5s")
        XCTAssertEqual(
            viewModel.failures.first?.reason, "Export failed — window past end of video")
    }

    func testPhotosSaveFailureIsNamedAsTheFailedStep() async {
        let fake = FakeExport(
            exportResults: Self.exportSuccesses(2),
            saveResults: [
                .success(()),
                .failure(ExportConfirmationError.photosSaveFailed(
                    reason: "Photos permission was revoked"))
            ])
        let viewModel = viewModel(items: [item(), item(start: 9, end: 11.5)], fake: fake)

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips[0].phase, .saved)
        XCTAssertEqual(
            viewModel.clips[1].phase,
            .failed(reason: "Couldn't save to Photos — Photos permission was revoked"))
        XCTAssertEqual(viewModel.summaryText, "1 of 2 clips saved to Photos")
    }

    func testUnknownErrorsFallBackToLocalizedDescription() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "kaput" }
        }
        let fake = FakeExport(exportResults: [.failure(Boom())])
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips[0].phase, .failed(reason: "kaput"))
        XCTAssertEqual(viewModel.summaryText, "0 of 1 clip saved to Photos")
    }

    func testProgressFractionsReachTheExportingPhase() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        await fake.setGateNextExport()
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitForFullExportProgress(viewModel)
        XCTAssertEqual(viewModel.clips[0].phase, .exporting(fraction: 1.0))
        await fake.openGate()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips[0].phase, .saved)
    }

    func testSavingPhaseIsVisibleWhileThePhotosWriteRuns() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        await fake.setGateNextSave()
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitForPhase(viewModel, .saving)
        XCTAssertEqual(viewModel.clips[0].phase, .saving)
        await fake.openGate()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips[0].phase, .saved)
    }

    func testCancelStopsTheRunAndKeepsRemainingClipsPending() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(2))
        await fake.setGateNextExport()
        let viewModel = viewModel(items: [item(), item(start: 9, end: 11.5)], fake: fake)

        viewModel.start()
        await Self.waitForFullExportProgress(viewModel)
        viewModel.cancel()
        await fake.openGate()
        await Self.waitUntilFinished(viewModel)

        // The in-flight clip finishes cooperatively; the cancelled run never starts the
        // next one, and the partial summary counts only what actually saved.
        XCTAssertEqual(viewModel.clips[0].phase, .saved)
        XCTAssertEqual(viewModel.clips[1].phase, .pending)
        XCTAssertTrue(viewModel.wasCancelled)
        XCTAssertEqual(viewModel.summaryText, "Export cancelled — 1 of 2 clips saved to Photos")
    }

    /// The exported files outlive their run: the share sheet hands the system a file
    /// URL, so the summary can only offer a Share action for files that are still on
    /// disk. The screen going away — `tearDown()` — is what removes them.
    func testScratchDirectorySurvivesTheRunAndIsRemovedOnTeardown() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        let viewModel = viewModel(
            items: [item()], fake: fake, makeDirectory: { directory })

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        let directoryExisted = await fake.directoryExistedAtCall
        XCTAssertEqual(directoryExisted, [true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(viewModel.clips[0].shareURL)

        viewModel.tearDown()
        await viewModel.cleanupTask?.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // The rows stop offering files that are on their way out, rather than
        // pointing the share sheet at a path the teardown just deleted.
        XCTAssertNil(viewModel.clips[0].fileURL)
        XCTAssertNil(viewModel.clips[0].shareURL)
    }

    func testExportedFileIsOfferedToTheShareSheet() async {
        let exported = URL(fileURLWithPath: "/tmp/fake-export-1.mp4")
        let fake = FakeExport(exportResults: [.success(exported)])
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips[0].phase, .saved)
        XCTAssertEqual(viewModel.clips[0].shareURL, exported)
    }

    /// Nothing is shareable before the export step returns: the file is still being
    /// written, and a share sheet over a half-written video fails at every
    /// destination.
    func testClipIsNotShareableWhileItIsStillExporting() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        await fake.setGateNextExport()
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitForFullExportProgress(viewModel)
        XCTAssertNil(viewModel.clips[0].shareURL)

        await fake.openGate()
        await Self.waitUntilFinished(viewModel)
        XCTAssertNotNil(viewModel.clips[0].shareURL)
    }

    /// The Photos write is the one in-flight step where the file URL is already
    /// recorded, so this discriminates the phase gate rather than the absence of a
    /// URL: dropping `.saving` from the unshareable side leaves this failing.
    func testClipIsNotShareableWhileThePhotosWriteRuns() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        await fake.setGateNextSave()
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitForPhase(viewModel, .saving)
        XCTAssertNotNil(viewModel.clips[0].fileURL)
        XCTAssertNil(viewModel.clips[0].shareURL)

        await fake.openGate()
        await Self.waitUntilFinished(viewModel)
        XCTAssertNotNil(viewModel.clips[0].shareURL)
    }

    /// A Photos-save failure leaves a perfectly good file on disk. Sharing it to
    /// Messages or AirDrop is the way out of a revoked Photos permission, so the
    /// failed row keeps its Share action.
    func testPhotosSaveFailureStillOffersTheFileForSharing() async {
        let exported = URL(fileURLWithPath: "/tmp/fake-export-1.mp4")
        let fake = FakeExport(
            exportResults: [.success(exported)],
            saveResults: [.failure(ExportConfirmationError.photosSaveFailed(reason: "denied"))])
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(
            viewModel.clips[0].phase,
            .failed(reason: "Couldn't save to Photos — denied"))
        XCTAssertEqual(viewModel.clips[0].shareURL, exported)
    }

    /// An export that never produced a file has nothing to hand off — the failed row
    /// must not offer a Share action over a file that was never written.
    func testExportFailureOffersNothingToShare() async {
        let fake = FakeExport(
            exportResults: [.failure(ExportConfirmationError.exportFailed(reason: "boom"))])
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips[0].phase, .failed(reason: "Export failed — boom"))
        XCTAssertNil(viewModel.clips[0].fileURL)
        XCTAssertNil(viewModel.clips[0].shareURL)
    }

    /// A restart re-exports every unfinished clip, so a clip that exported but failed
    /// its Photos write has its URL dropped at the reset rather than left pointing at
    /// the output the new run is about to replace. Asserted on `fileURL`, not
    /// `shareURL`: a clip mid-restart is unshareable either way, so only the stored
    /// URL discriminates the reset.
    func testRestartDropsTheSupersededFileURL() async {
        let first = URL(fileURLWithPath: "/tmp/fake-export-1.mp4")
        let second = URL(fileURLWithPath: "/tmp/fake-export-2.mp4")
        let third = URL(fileURLWithPath: "/tmp/fake-export-3.mp4")
        let fake = FakeExport(
            exportResults: [.success(first), .success(second), .success(third)],
            saveResults: [.failure(ExportConfirmationError.photosSaveFailed(reason: "denied"))])
        // Park the second export — the run is only restartable while it is still
        // draining, and clip 1 must have finished failing before that.
        await fake.setGatedExportCalls([1])
        let viewModel = viewModel(items: [item(), item(start: 9, end: 11.5)], fake: fake)

        viewModel.start()
        await Self.waitForFullExportProgress(viewModel, index: 1)
        XCTAssertEqual(viewModel.clips[0].fileURL, first)

        viewModel.cancel()
        viewModel.start(userInitiated: true)
        XCTAssertEqual(viewModel.clips[0].phase, .pending)
        XCTAssertNil(viewModel.clips[0].fileURL)

        await fake.openGate()
        await Self.waitUntilFinished(viewModel)
        XCTAssertEqual(viewModel.clips[0].phase, .saved)
        XCTAssertEqual(viewModel.clips[0].fileURL, third)
    }

    /// One scratch directory per screen, not per run: a restart writing into a fresh
    /// directory would strand the files the earlier run already exported, and their
    /// rows go on offering a Share action for them.
    func testRestartExportsIntoTheSameScratchDirectory() async {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let fake = FakeExport(exportResults: Self.exportSuccesses(2))
        await fake.setGateNextExport()
        let viewModel = viewModel(
            items: [item(), item(start: 9, end: 11.5)], fake: fake,
            // A fresh directory per call, so the assertion below discriminates: with
            // a per-run directory the two exports land in different folders.
            makeDirectory: {
                parent.appendingPathComponent(
                    "\(exportDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
            })

        viewModel.start()
        await Self.waitForFullExportProgress(viewModel)
        viewModel.cancel()
        viewModel.start(userInitiated: true)
        await fake.openGate()
        await Self.waitUntilFinished(viewModel)

        let directories = await fake.directoriesAtCall
        XCTAssertEqual(directories.count, 2)
        XCTAssertEqual(Set(directories).count, 1)
    }

    /// A killed run never executes `start()`'s cleanup `defer`, orphaning its
    /// `turnip-export-*` scratch directory. Each new run sweeps those stale
    /// siblings at start; without the sweep this test leaves the orphan behind,
    /// and a name without the prefix must never be touched.
    func testStaleExportDirectoriesAreSweptAtRunStart() async {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-test-\(UUID().uuidString)", isDirectory: true)
        let orphan = parent.appendingPathComponent(
            "\(exportDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
        let unrelated = parent.appendingPathComponent(
            "turnip-keep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        let viewModel = viewModel(
            items: [item()], fake: fake,
            makeDirectory: {
                parent.appendingPathComponent(
                    "\(exportDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
            })

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(viewModel.clips[0].phase, .saved)
    }

    func testProgressFractionsAreClampedToTheUnitRange() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        await fake.setProgressFractions([2.0, -1.0])
        await fake.setGateNextExport()
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        // Ticks are clamped to the unit range and the phase never moves backwards:
        // the max wins, so the order the two unstructured tick tasks land in can't
        // matter — [2.0, -1.0] settles at 1.0 either way.
        await Self.waitForPhase(viewModel, .exporting(fraction: 1.0))
        XCTAssertEqual(viewModel.clips[0].phase, .exporting(fraction: 1.0))
        await fake.openGate()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips[0].phase, .saved)
    }

    /// The stale-tick guard in `reportExportProgress` is load-bearing but was
    /// untested: a tick dispatched just before `exportClip` returns hops to the
    /// main actor on its own task, so it can land after the phase moved on, and
    /// must not clobber `.saving` / `.saved` / `.failed`. Without the
    /// `guard case .exporting` this test fails with `.exporting(fraction: 0.9)`.
    func testStaleProgressTickDoesNotClobberSavingPhase() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        await fake.setStashProgressHandler()
        // The save is gated, so the run sits in `.saving` after the export returns.
        await fake.setGateNextSave()
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitForPhase(viewModel, .saving)
        XCTAssertEqual(viewModel.clips[0].phase, .saving)

        // A stale tick from the finished export, landing after the phase moved on.
        let handlers = await fake.stashedProgressHandlers
        XCTAssertEqual(handlers.count, 1)
        handlers[0](0.9)
        // Let the tick's MainActor hop land: without the guard it flips the phase.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.clips[0].phase, .saving)

        await fake.openGate()
        await Self.waitUntilFinished(viewModel)
        XCTAssertEqual(viewModel.clips[0].phase, .saved)
    }

    func testStartAfterFinishDoesNotReexport() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        await Self.waitUntilFinished(viewModel)
        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        let calls = await fake.exportCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(viewModel.isFinished)
    }

    /// The view's `.task` re-fires on re-appear with a plain `start()` — and the view
    /// also cancels on disappear — so a re-appear while the cancelled run is still
    /// draining must not resurrect it: only an explicit user gesture restarts. Without
    /// the `userInitiated` gate, the second `start()` below treats the draining run as
    /// a genuine restart and exports the second clip a second time.
    func testReappearAfterCancelDoesNotRestartRun() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(2))
        await fake.setGateNextExport()
        let viewModel = viewModel(items: [item(), item(start: 9, end: 11.5)], fake: fake)

        viewModel.start()
        await Self.waitForFullExportProgress(viewModel)
        // Disappear cancels the run; the re-appear's `.task` re-fire calls plain
        // `start()` — not a user gesture — while the cancelled run still drains.
        viewModel.cancel()
        viewModel.start()
        await fake.openGate()
        await Self.waitUntilFinished(viewModel)

        // The re-appear start was ignored: only the first run's export ran, the
        // cancelled run drained honestly, and the second clip was never exported.
        let exportCallCount = await fake.exportCalls.count
        XCTAssertEqual(exportCallCount, 1)
        XCTAssertEqual(viewModel.clips.map(\.phase), [.saved, .pending])
        XCTAssertTrue(viewModel.wasCancelled)
        XCTAssertTrue(viewModel.isFinished)
    }

    /// A restart after cancel is a genuine restart, not a second concurrent run: run 2
    /// waits for run 1 to drain, run 1's stale teardown can't end the screen under it,
    /// and a clip run 1 already saved is skipped rather than written to Photos twice.
    func testStaleTeardownDoesNotFinishNewerRun() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(2))
        let viewModel = viewModel(items: [item(), item(start: 9, end: 11.5)], fake: fake)

        // Run 1 blocks inside its first export, so cancel() leaves it draining.
        await fake.setGateNextExport()
        viewModel.start()
        await Self.waitForFullExportProgress(viewModel)
        viewModel.cancel()

        // Run 2 starts while run 1 is still draining — the explicit user-initiated
        // restart path (`start(userInitiated:)`). Its export is gated up front so
        // run 1 is guaranteed to reach its trailing teardown while run 2 is parked.
        await fake.setGateNextExport()
        viewModel.start(userInitiated: true)
        await fake.openGate()
        // Cancellation is per-run: run 1's stale teardown must not flip wasCancelled
        // or isFinished under the newer run. Give it a beat to land.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // The stale teardown must not end the screen under the newer run: without the
        // generation guard this flips isFinished and nils the new run's handle here.
        XCTAssertFalse(viewModel.isFinished)
        XCTAssertTrue(viewModel.isRunning)
        XCTAssertFalse(viewModel.wasCancelled)

        await fake.openGate()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips.map(\.phase), [.saved, .saved])
        XCTAssertEqual(viewModel.summaryText, "2 of 2 clips saved to Photos")
        // Run 1's export ran (call 1): cancel() only cancels the task, so the
        // parked continuation still completed and saved clip 1 once the gate
        // opened. Run 2 then skipped the already-saved clip 1 and exported
        // only clip 2 (call 2) — each clip reached Photos exactly once.
        let exportCallCount = await fake.exportCalls.count
        XCTAssertEqual(exportCallCount, 2)
        let savedURLs = await fake.savedURLs
        XCTAssertEqual(savedURLs.count, 2)
    }
}

private extension ExportConfirmationViewModelTests.FakeExport {
    func setGateNextExport() { gateNextExport = true }
    func setGateNextSave() { gateNextSave = true }
    func setProgressFractions(_ fractions: [Double]) { progressFractions = fractions }
    func setStashProgressHandler() { stashProgressHandler = true }
    func setGatedExportCalls(_ indices: Set<Int>) { gatedExportCalls = indices }
}
