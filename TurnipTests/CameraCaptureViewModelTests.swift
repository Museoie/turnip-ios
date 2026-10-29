import XCTest
@testable import Turnip

/// The pre-recording gate (#205): Record must refuse, not crash, when the
/// movie output has no video connection — the state on any device where the
/// output could not be attached (including the simulator, which is also
/// the first thing a new contributor runs).
@MainActor
final class CameraCaptureViewModelTests: XCTestCase {
    func testToggleRecordingRefusesWithoutAConfiguredSession() {
        // No `start()` call: the session was never configured and the movie
        // output has no connection. Before the guard this reached
        // `startRecording` and raised an uncatchable NSInvalidArgumentException.
        let viewModel = CameraCaptureViewModel(settingsProvider: {
            TurnipSettings(analysisMode: .offline)
        })
        XCTAssertFalse(viewModel.hasCaptureDevice)

        viewModel.toggleRecording()

        XCTAssertFalse(viewModel.isRecording)
    }

    func testToggleRecordingRefusesInRealTimeModeToo() {
        // Real-time mode arms the live-pose tap first; the arm guards on
        // the same missing connections, so the refusal must hold there too.
        let viewModel = CameraCaptureViewModel(settingsProvider: {
            TurnipSettings(analysisMode: .realTime)
        })

        viewModel.toggleRecording()

        XCTAssertFalse(viewModel.isRecording)
    }

    func testHasCaptureDeviceStartsFalse() {
        // The record button gates on this flag, so it must start in the
        // not-ready state and only flip once configuration completes.
        let viewModel = CameraCaptureViewModel(settingsProvider: { TurnipSettings() })
        XCTAssertFalse(viewModel.hasCaptureDevice)
        XCTAssertFalse(viewModel.isFinishingRecording)
    }
}
