import Photos

/// The access states docs/UIUX.md § "Home / Video Gallery" requires Home to tell apart, collapsed
/// from PhotoKit's `PHAuthorizationStatus`. Kept as its own type so the mapping is unit-testable
/// and the views never switch on PhotoKit's enum (which grows `@unknown` cases across SDKs).
enum PhotoLibraryAuthorization: Equatable {
    /// The system prompt hasn't been shown yet — Home should request access on appear.
    case notDetermined
    /// Full library read access: render every video.
    case authorized
    /// The user granted a subset of the library (iOS 14+): render that subset plus an affordance
    /// to grant more (`PHPhotoLibrary.presentLimitedLibraryPicker`).
    case limited
    /// No access. There's no picker fallback once Home *is* the gallery, so this is an empty state.
    /// `restricted` is true when a parental-control / MDM restriction blocks access — in that case
    /// the user can't fix it from Settings, so the empty state shouldn't send them there.
    case denied(restricted: Bool)

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .authorized
        case .limited:
            self = .limited
        case .denied:
            self = .denied(restricted: false)
        case .restricted:
            self = .denied(restricted: true)
        @unknown default:
            // A status this build doesn't know about is by definition not one we've been granted;
            // fail closed rather than enumerating a library we may not be allowed to read.
            self = .denied(restricted: false)
        }
    }

    /// Whether `PHAsset.fetchAssets` will return anything — true for both full and limited access.
    var canReadLibrary: Bool {
        switch self {
        case .authorized, .limited:
            return true
        case .notDetermined, .denied:
            return false
        }
    }
}
