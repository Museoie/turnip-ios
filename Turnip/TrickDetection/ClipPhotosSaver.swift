import Foundation
import Photos

/// Writes exported clips into the user's Photos library.
///
/// Add-only: saving needs no Photos authorization prompt, and nothing is read back, so the
/// v1 "nothing leaves the device" promise holds — the file goes from the app's sandbox to
/// the on-device library. `NSPhotoLibraryAddUsageDescription` in Info.plist covers the
/// usage string iOS shows if the system ever asks.
struct ClipPhotosSaver: Sendable {
    /// Saves one exported video file to Photos. The file must exist; the caller decides
    /// when to delete the sandbox copy afterwards.
    func saveVideo(at fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ClipExportError.exportFailed(
                reason: "no exported file at \(fileURL.lastPathComponent)")
        }
        // The change block can't throw, so a nil creation request is reported with a flag.
        var requestAccepted = false
        try await PHPhotoLibrary.shared().performChanges {
            requestAccepted =
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL) != nil
        }
        guard requestAccepted else {
            throw ClipExportError.exportFailed(
                reason: "Photos rejected the creation request for \(fileURL.lastPathComponent)")
        }
    }
}
