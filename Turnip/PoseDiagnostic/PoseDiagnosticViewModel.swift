import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class PoseDiagnosticViewModel: ObservableObject {
    @Published private(set) var results: [PoseFrameResult] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?

    private let sampler = VideoFrameSampler()
    private var runTask: Task<Void, Never>?

    /// Popping the screen has to stop the run. Without this a swipe-back would leave a full decode
    /// plus per-frame inference burning the device with no consumer, and every back-and-tap would
    /// stack another one against the same cooperative pool.
    deinit {
        runTask?.cancel()
    }

    /// Runs MoveNet Thunder over `asset`, the video Home resolved from the tapped tile (see
    /// `SelectedVideo`).
    func runDiagnostic(on asset: AVURLAsset) {
        guard !isRunning else { return }
        results = []
        errorMessage = nil
        isRunning = true

        // `weak self` is what makes `deinit` reachable at all: a strong capture would keep this
        // view model alive for as long as the run it is supposed to be cancelled by.
        runTask = Task { [weak self, sampler] in
            defer { self?.isRunning = false }
            do {
                let model = try await MoveNetThunderModel.load()
                try await sampler.sampleFrames(from: asset) { frame in
                    let keypoints = try await model.runInference(on: frame.pixelBuffer)
                    let result = PoseFrameResult(
                        frameIndex: frame.frameIndex,
                        timestamp: frame.timestamp,
                        keypoints: keypoints
                    )
                    PoseResultLogger.log(result)
                    await MainActor.run {
                        self?.results.append(result)
                    }
                }
            } catch is CancellationError {
                // The screen went away mid-run; there is nobody left to tell.
            } catch let error as PoseError {
                self?.errorMessage = error.errorDescription
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }
}
