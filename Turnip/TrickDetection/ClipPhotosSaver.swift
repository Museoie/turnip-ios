import Foundation
import Photos

/// Failures saving an exported clip to Photos, typed so the caller can tell "send the
/// user to Settings" apart from "retry" without string-matching — the outcome
/// `ClipExportError`'s docstring says the exporter's typed errors exist to prevent.
enum ClipPhotosSaveError: LocalizedError, Equatable {
    /// The exported file was missing when the save was attempted.
    case missingInputFile(URL)
    /// The user denied the add-only Photos prompt. `restricted` is true when a
    /// parental-control / MDM restriction blocks access — in that case the user can't
    /// fix it from Settings, so the UI shouldn't send them there.
    case authorizationDenied(restricted: Bool)
    /// PhotoKit rejected the save after authorization was granted.
    case saveRejected(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingInputFile:
            return "This video is no longer available to save."
        case .authorizationDenied(let restricted):
            return restricted
                ? "Photos access is restricted on this device, so Turnip can't save to it."
                : "Turnip needs access to Photos to save this video. Allow access in Settings."
        case .saveRejected(let reason):
            return "Couldn't save this video to Photos. (\(reason))"
        }
    }
}

/// Writes exported clips into the user's Photos library.
///
/// Add-only: saving goes through the add-only authorization prompt
/// (`NSPhotoLibraryAddUsageDescription` in Info.plist covers the usage string). The v1 "nothing
/// leaves the device" promise still holds — every read this type does (`fetchAlbum(titled:)`
/// below, checking for an existing album before creating a duplicate) stays inside the device's
/// own Photos library, never the network.
///
/// **Unverified assumption, needs a device pass before this is trusted:** `fetchAlbum(titled:)`
/// is written on the assumption that add-only authorization limits what it can find to albums
/// this saver itself created in an earlier call — `PHAccessLevel.addOnly`'s general contract is
/// read visibility scoped to what the app added, but `fetchAssetCollections(with:subtype:options:)`
/// takes no parameter that states this, and it has not been run under either full or limited
/// Photos access on a real device or Simulator (none available in this environment). Two ways
/// that assumption can be wrong, both degrading to the same outcome via `addToAlbum`'s fallback:
/// - **The fetch sees nothing** (a collision with an album another app created, invisible under
///   add-only).
/// - **The fetch sees an album it can't edit** (the complementary collision: an existing album
///   this saver didn't create, visible but not modifiable under add-only — `PHAssetCollectionChangeRequest`
///   returns `nil`).
///
/// Either way, `addToAlbum` creates a new album with the SAME title instead of adding to the
/// one `fetchAlbum` found or failed to find — so a Photos search for that title can turn up
/// more than one album, all named identically, none of them "the wrong one" to look in. The
/// clip still lands *somewhere*, just not consolidated — a save never fails or drops album
/// membership because of this, it can only spread one save's worth of clips across an extra,
/// same-titled album per occurrence.
struct ClipPhotosSaver: Sendable {
    /// Resolves the add-only Photos authorization, collapsed onto the app's
    /// shared Photos-domain authorization model (`PhotoLibraryAuthorization`,
    /// also used by the Home gallery).
    /// Injected so tests can drive the denial paths without a system prompt; production
    /// passes the live add-only request.
    var authorization: @Sendable () async -> PhotoLibraryAuthorization = {
        PhotoLibraryAuthorization(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
    }

    /// Saves one exported video file to Photos, returning the created asset's
    /// `PHAsset.localIdentifier`. The file must exist; the caller decides when to delete
    /// the sandbox copy afterwards.
    ///
    /// `albumTitle` is the Settings screen's "Save to an album" option
    /// (`TurnipSettings.albumDestination`): `nil` (the default) creates the asset
    /// with no album, landing wherever an ordinary Photos creation request lands it.
    /// A non-nil title adds the new asset to that album, creating it first if it doesn't already
    /// exist, both inside the one change block below, so the asset and its album membership
    /// either both land or neither does — `addToAlbum`'s fallback (see its doc comment) means
    /// the album it lands in isn't always the one `albumTitle` names, but membership in *some*
    /// album with that title is never separated from the asset's own creation.
    @discardableResult
    func saveVideo(at fileURL: URL, albumTitle: String? = nil) async throws -> String {
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
        var createdIdentifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let placeholder = PHAssetCreationRequest
                    .creationRequestForAssetFromVideo(atFileURL: fileURL)?
                    .placeholderForCreatedAsset else { return }
                createdIdentifier = placeholder.localIdentifier
                guard let albumTitle else { return }
                Self.addToAlbum(placeholder, titled: albumTitle)
            }
        } catch {
            throw ClipPhotosSaveError.saveRejected(reason: error.localizedDescription)
        }
        guard let createdIdentifier else {
            throw ClipPhotosSaveError.saveRejected(
                reason: "Photos rejected the creation request for \(fileURL.lastPathComponent)")
        }
        return createdIdentifier
    }

    /// An existing album titled `title` this fetch can see, or `nil` when none is visible —
    /// checked inside the same change block that would otherwise create a duplicate, so
    /// re-saving with the same album name adds to the one album instead of making a new one
    /// each time. See the type-level doc comment above for what "visible" means under add-only
    /// authorization, and that this is unverified.
    private static func fetchAlbum(titled title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        return PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        ).firstObject
    }

    /// Adds `placeholder` to the album titled `title`, creating a new same-titled album if
    /// `fetchAlbum` doesn't find one — OR if it finds one this app can't edit
    /// (`PHAssetCollectionChangeRequest` returns `nil` for a `fetchAlbum` hit that isn't
    /// add-only-modifiable): both cases fall through to the same creation branch, so an
    /// unmodifiable existing album degrades into the same-titled-duplicate outcome
    /// `fetchAlbum`'s doc comment already discloses for the sees-nothing case, rather than a
    /// distinct failure mode. Must run inside a `PHPhotoLibrary.performChanges` block.
    private static func addToAlbum(_ placeholder: PHObjectPlaceholder, titled title: String) {
        if let existingAlbum = fetchAlbum(titled: title),
            let editRequest = PHAssetCollectionChangeRequest(for: existingAlbum) {
            editRequest.addAssets([placeholder] as NSArray)
        } else {
            PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: title)
                .addAssets([placeholder] as NSArray)
        }
    }
}
