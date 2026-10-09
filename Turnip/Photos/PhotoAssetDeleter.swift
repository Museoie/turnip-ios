import Photos

/// Deletes one asset from the Photos library by its `PHAsset.localIdentifier`. A
/// separate type from `ClipPhotosSaver`, whose docstring promises add-only access —
/// this one needs the write half of `.readWrite`, which Home already requests to
/// enumerate the library.
///
/// PhotoKit shows its own "Allow Turnip to delete?" confirmation before
/// `performChanges` resolves; a decline surfaces as a thrown error indistinguishable
/// from any other rejected change, so the caller treats every failure here as
/// non-fatal and leaves the asset in place.
struct PhotoAssetDeleter: Sendable {
    /// A no-op when the identifier no longer resolves to an asset — already deleted
    /// (by this call or elsewhere) is the same outcome as deleted.
    func delete(assetIdentifier: String) async throws {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier], options: nil
        ).firstObject else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }
}
