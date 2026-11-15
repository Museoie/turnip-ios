import Photos

/// Deletes assets from the Photos library by their `PHAsset.localIdentifier`s. A
/// separate type from `ClipPhotosSaver`, whose docstring promises add-only access —
/// this one needs the write half of `.readWrite`, which Home already requests to
/// enumerate the library.
///
/// PhotoKit shows its own "Allow Turnip to delete?" confirmation before
/// `performChanges` resolves; a decline surfaces as a thrown error indistinguishable
/// from any other rejected change, and the asset stays in place.
struct PhotoAssetDeleter: Sendable {
    /// Deletes every asset the identifiers still resolve to in one change, so PhotoKit asks
    /// once for all of them; a decline keeps every one. An identifier that no longer resolves
    /// is skipped — already deleted (by this call or elsewhere) is the same outcome as deleted —
    /// and none resolving is a no-op.
    func delete(assetIdentifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
