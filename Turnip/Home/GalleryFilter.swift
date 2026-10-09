import Photos

/// Home's gallery filter selection — mirrors the Photos app's own filter menu: All Items,
/// Favorites, or a specific user album. "Edited" is deliberately not offered: PhotoKit has no
/// fetch-level predicate for it, only a per-asset `PHAssetResource` scan, which would make
/// every filter change scale with library size instead of staying fetch-level like the other
/// cases.
enum GalleryFilter: Equatable {
    case all
    case favorites
    case album(PHAssetCollection)

    /// Explicit negative arms rather than a `default: return false` catch-all: a future case
    /// added to the enum makes this switch non-exhaustive and fails to compile instead of
    /// silently comparing unequal to itself.
    static func == (lhs: GalleryFilter, rhs: GalleryFilter) -> Bool {
        switch (lhs, rhs) {
        case (.all, .all), (.favorites, .favorites):
            return true
        case (.album(let left), .album(let right)):
            return left.localIdentifier == right.localIdentifier
        case (.all, _), (.favorites, _), (.album, _):
            return false
        }
    }

    /// The `PHFetchOptions.predicate` for this filter, always restricted to videos. Pure and
    /// separated from `VideoLibraryViewModel` so the mapping is unit-testable without a real
    /// `PHPhotoLibrary`.
    var predicate: NSPredicate {
        let video = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        switch self {
        case .all, .album:
            return video
        case .favorites:
            return NSCompoundPredicate(
                andPredicateWithSubpredicates: [video, NSPredicate(format: "favorite == YES")])
        }
    }

    /// Display text for the filter menu's rows and the empty-state message.
    var label: String {
        switch self {
        case .all: return "All Items"
        case .favorites: return "Favorites"
        case .album(let collection): return collection.localizedTitle ?? "Album"
        }
    }
}
