import Foundation
import Photos

/// Failures saving an exported clip to Photos, typed so the caller can tell "send the
/// user to Settings" apart from "retry" without string-matching — the outcome
/// `ClipExportError`'s docstring says the exporter's typed errors exist to prevent.
enum ClipPhotosSaveError: Error, Equatable {
    /// The exported file was missing when the save was attempted.
    case missingInputFile(URL)
    /// The user denied the add-only Photos prompt. `restricted` is true when a
    /// parental-control / MDM restriction blocks access — in that case the user can't
    /// fix it from Settings, so the UI shouldn't send them there.
    case authorizationDenied(restricted: Bool)
    /// PhotoKit rejected the save after authorization was granted.
    case saveRejected(reason: String)
}

/// Writes exported clips into the user's Photos library.
///
/// Add-only: saving goes through the add-only authorization prompt
/// (`NSPhotoLibraryAddUsageDescription` in Info.plist covers the usage string), and
/// nothing is read back, so the v1 "nothing leaves the device" promise holds — the file
/// goes from the app's sandbox to the on-device library.
struct ClipPhotosSaver: Sendable {
    /// Resolves the add-only Photos authorization, collapsed onto the app's
    /// authorization model (`PhotoLibraryAuthorization`, shared with Home's gallery).
    /// Injected so tests can drive the denial paths without a system prompt; production
    /// passes the live add-only request.
    var authorization: @Sendable () async -> PhotoLibraryAuthorization = {
        PhotoLibraryAuthorization(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    /// Saves one exported video file to Photos. The file must exist; the caller decides
    /// when to delete the sandbox copy afterwards.
    func saveVideo(at fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ClipPhotosSaveError.missingInputFile(fileURL)
        }
        switch await authorization() {
        case .authorized:
            break
        case .denied(let restricted):
            throw ClipPhotosSaveError.authorizationDenied(restricted: restricted)
        case .notDetermined, .limited:
            // requestAuthorization(for:) answers the prompt itself, so these mean a
            // status this build doesn't understand — fail closed rather than saving
            // into a library state we can't reason about.
            throw ClipPhotosSaveError.authorizationDenied(restricted: false)
        }
        // The change block can't throw, so a nil creation request is reported with a flag.
        // The commit itself throws a raw PhotoKit NSError (out of space, asset rejected);
        // it is wrapped so every failure out of this method is a ClipPhotosSaveError.
        var requestAccepted = false
        do {
            try await PHPhotoLibrary.shared().performChanges {
                requestAccepted =
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL) != nil
            }
        } catch {
            throw ClipPhotosSaveError.saveRejected(reason: error.localizedDescription)
        }
        guard requestAccepted else {
            throw ClipPhotosSaveError.saveRejected(
                reason: "Photos rejected the creation request for \(fileURL.lastPathComponent)")
        }
    }
}
