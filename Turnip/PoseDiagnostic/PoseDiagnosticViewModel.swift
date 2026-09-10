import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Wraps a picked video's data in a file URL — PhotosPickerItem doesn't hand one over directly.
struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

@MainActor
final class PoseDiagnosticViewModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem?
    @Published private(set) var results: [PoseFrameResult] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?

    private let sampler = VideoFrameSampler()

    func runDiagnostic() {
        guard let selectedItem else { return }
        results = []
        errorMessage = nil
        isRunning = true

        Task {
            defer { isRunning = false }
            do {
                let videoURL = try await Self.loadVideoURL(from: selectedItem)
                let model = try await MoveNetThunderModel.load()
                try await sampler.sampleFrames(from: videoURL) { frame in
                    let keypoints = try await model.runInference(on: frame.pixelBuffer)
                    let result = PoseFrameResult(
                        frameIndex: frame.frameIndex,
                        timestamp: frame.timestamp,
                        keypoints: keypoints
                    )
                    PoseResultLogger.log(result)
                    await MainActor.run {
                        self.results.append(result)
                    }
                }
            } catch let error as PoseDiagnosticError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func loadVideoURL(from item: PhotosPickerItem) async throws -> URL {
        guard let movie = try await item.loadTransferable(type: Movie.self) else {
            throw PoseDiagnosticError.videoLoadFailed(underlying: nil)
        }
        return movie.url
    }
}
