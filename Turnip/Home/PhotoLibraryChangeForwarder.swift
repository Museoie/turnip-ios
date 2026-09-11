import Photos

/// `PHPhotoLibraryChangeObserver` requires an `NSObject`, and PhotoKit calls it on an arbitrary
/// background queue. This adapter keeps that out of the `@MainActor` view model: it just forwards
/// each change to a closure, and the view model hops to the main actor itself.
final class PhotoLibraryChangeForwarder: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable (PHChange) -> Void

    init(onChange: @escaping @Sendable (PHChange) -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange(changeInstance)
    }
}
