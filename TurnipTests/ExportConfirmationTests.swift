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
    private actor FakeExport {
        var exportCalls: [(window: TrickWindow, cropRect: NormalizedRect)] = []
        var savedURLs: [URL] = []
        var directoryExistedAtCall: [Bool] = []
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
        var gateNextSave = false
        private var gate: CheckedContinuation<Void, Never>?

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
            _ progress: @Sendable (Double) -> Void
        ) async throws -> URL {
            exportCalls.append((window, cropRect))
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
            if gateNextExport {
                gateNextExport = false
                await withCheckedContinuation { self.gate = $0 }
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
                await withCheckedContinuation { self.gate = $0 }
            }
            guard !saveResults.isEmpty else { return }
            try saveResults.removeFirst().get()
        }

        func openGate() {
            gate?.resume()
            gate = nil
        }
    }

    private func viewModel(
        items: [ExportConfirmationItem],
        fake: FakeExport,
        makeDirectory: (@Sendable () -> URL)? = nil
    ) -> ExportConfirmationViewModel {
        ExportConfirmationViewModel(
            items: items,
            asset: AVAsset(),
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
            .success(URL(fileURLWithPath: "/tmp/c.mp4")),
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
                    reason: "Photos permission was revoked")),
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

    func testScratchDirectoryIsCreatedForTheRunAndRemovedAfter() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-test-\(UUID().uuidString)", isDirectory: true)
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        let viewModel = viewModel(
            items: [item()], fake: fake, makeDirectory: { directory })

        viewModel.start()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(await fake.directoryExistedAtCall, [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testProgressFractionsAreClampedToTheUnitRange() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(1))
        await fake.setProgressFractions([2.0, -1.0])
        await fake.setGateNextExport()
        let viewModel = viewModel(items: [item()], fake: fake)

        viewModel.start()
        // Both ticks are reported before the gate, so the last one wins — clamped.
        await Self.waitForPhase(viewModel, .exporting(fraction: 0.0))
        XCTAssertEqual(viewModel.clips[0].phase, .exporting(fraction: 0.0))
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

    func testStaleTeardownDoesNotFinishNewerRun() async {
        let fake = FakeExport(exportResults: Self.exportSuccesses(2))
        let viewModel = viewModel(items: [item(), item(start: 9, end: 11.5)], fake: fake)

        // Run 1 blocks inside its first export, so cancel() leaves it draining while
        // runTask is already nil.
        await fake.setGateNextExport()
        viewModel.start()
        await Self.waitForFullExportProgress(viewModel)
        viewModel.cancel()

        // Run 2 starts while run 1 is still draining. Its export is gated up front so
        // run 1 is guaranteed to reach its trailing teardown while run 2 is parked.
        await fake.setGateNextExport()
        viewModel.start()
        await fake.openGate()
        for _ in 0..<200 where !viewModel.wasCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // Let run 1's trailing teardown land while run 2 cannot progress.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The stale teardown must not end the screen under the newer run: without the
        // generation guard this flips isFinished and nils the new run's handle here.
        XCTAssertFalse(viewModel.isFinished)
        XCTAssertTrue(viewModel.isRunning)

        await fake.openGate()
        await Self.waitUntilFinished(viewModel)

        XCTAssertEqual(viewModel.clips.map(\.phase), [.saved, .saved])
        XCTAssertEqual(viewModel.summaryText, "2 of 2 clips saved to Photos")
        XCTAssertEqual((await fake.exportCalls).count, 3)
    }
}

private extension ExportConfirmationViewModelTests.FakeExport {
    func setGateNextExport() { gateNextExport = true }
    func setGateNextSave() { gateNextSave = true }
    func setProgressFractions(_ fractions: [Double]) { progressFractions = fractions }
    func setStashProgressHandler() { stashProgressHandler = true }
}
