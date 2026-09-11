import AVFoundation
import Foundation
import Photos
import PhotosUI
import UIKit

/// Backs Home: Photos authorization, the video `PHAsset` list, and turning a tapped tile into a
/// `SelectedVideo` pushed onto the navigation path.
@MainActor
final class VideoLibraryViewModel: ObservableObject {
    /// A tile tap in progress. `downloadProgress` is nil until PhotoKit reports the first iCloud
    /// progress callback — local assets resolve without ever setting it.
    struct Resolution: Equatable {
        let assetIdentifier: String
        var downloadProgress: Double?
    }

    /// How many assets to materialize per page. The grid only ever holds a prefix of the fetch
    /// result, so a library with thousands of videos costs the same on first load as one with 60.
    static let pageSize = 60
    /// Start loading the next page when the user is this many tiles from the end of the loaded
    /// prefix — a bit more than one screen at 3 columns, so the grid never visibly runs out.
    static let loadMoreThreshold = 18

    @Published private(set) var authorization: PhotoLibraryAuthorization
    /// Newest first. The loaded prefix of `fetchResult`, grown a page at a time as the user scrolls
    /// (`tileAppeared(at:)`). `PHAsset` objects are lightweight faults; the expensive part
    /// (thumbnails) is loaded lazily per visible tile and prefetched around it by `thumbnails`.
    @Published private(set) var videos: [PHAsset] = []
    /// False until the first fetch has run. Authorization resolves synchronously in `init`, so an
    /// already-authorized cold launch would otherwise render the "no videos" empty state for one
    /// frame before `reload()` has looked.
    @Published private(set) var hasLoaded = false
    @Published private(set) var resolution: Resolution?
    @Published var errorMessage: String?
    @Published var path: [SelectedVideo] = []

    let thumbnails = ThumbnailLoader()

    private let library: PHPhotoLibrary
    private let resolver: PhotoVideoResolver
    private var fetchResult: PHFetchResult<PHAsset>?
    private var changeForwarder: PhotoLibraryChangeForwarder?
    private var resolveTask: Task<Void, Never>?

    init(library: PHPhotoLibrary = .shared(), resolver: PhotoVideoResolver = PhotoVideoResolver()) {
        self.library = library
        self.resolver = resolver
        authorization = PhotoLibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    deinit {
        if let changeForwarder {
            library.unregisterChangeObserver(changeForwarder)
        }
    }

    // MARK: - Authorization + loading

    /// Prompts for access on first launch, then loads the grid. Safe to call again — a second
    /// call after a prompt just reloads.
    ///
    /// `.readWrite` rather than a read-only level because PhotoKit has none: the choices are
    /// add-only (can't enumerate) or read/write. Exporting clips back to Photos needs the write
    /// half anyway.
    func start() async {
        if authorization == .notDetermined {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            authorization = PhotoLibraryAuthorization(status)
        }
        reload()
    }

    func reload() {
        defer { hasLoaded = true }
        guard authorization.canReadLibrary else {
            fetchResult = nil
            replaceVideos(with: [])
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        fetchResult = result
        replaceVideos(with: Self.prefix(of: result, count: Self.pageSize))
        observeLibraryChanges()
    }

    /// Limited-access affordance: iOS's own picker for extending the granted subset. Presented
    /// from UIKit because SwiftUI has no wrapper for it.
    func presentLimitedLibraryPicker() {
        guard let presenter = UIApplication.shared.topViewController else { return }
        library.presentLimitedLibraryPicker(from: presenter) { [weak self] _ in
            // The change observer fires too, but the completion is the deterministic signal.
            Task { @MainActor in self?.reload() }
        }
    }

    /// Called by the grid as each tile appears: keeps the thumbnail cache centered on the visible
    /// region and grows the loaded prefix when the user nears its end.
    func tileAppeared(at index: Int) {
        thumbnails.tileAppeared(at: index, in: videos)
        if index >= videos.count - Self.loadMoreThreshold {
            loadNextPage()
        }
    }

    private func loadNextPage() {
        guard let fetchResult, videos.count < fetchResult.count else { return }
        let end = min(fetchResult.count, videos.count + Self.pageSize)
        videos.append(contentsOf: fetchResult.objects(at: IndexSet(integersIn: videos.count..<end)))
    }

    private func observeLibraryChanges() {
        guard changeForwarder == nil else { return }
        let forwarder = PhotoLibraryChangeForwarder { [weak self] change in
            Task { @MainActor in self?.apply(change) }
        }
        library.register(forwarder)
        changeForwarder = forwarder
    }

    /// What a library change means for the grid, as plain values. `PHChange` and
    /// `PHFetchResultChangeDetails` have no public initializer, so this is the only part of
    /// `apply(_:)` that can be exercised directly.
    struct LibraryChangeUpdate: Equatable {
        /// How much of the updated fetch result to materialize.
        let prefixCount: Int
        /// Which thumbnails to re-request.
        let invalidatedIdentifiers: Set<String>
    }

    static func libraryChangeUpdate(
        loadedCount: Int,
        hasIncrementalChanges: Bool,
        changedIdentifiers: () -> [String]
    ) -> LibraryChangeUpdate {
        LibraryChangeUpdate(
            // Never shrink below what the user has already scrolled past, nor below one page.
            prefixCount: max(loadedCount, pageSize),
            // `changedObjects` is only populated for an incremental change, so it is not even
            // evaluated otherwise.
            invalidatedIdentifiers: hasIncrementalChanges ? Set(changedIdentifiers()) : []
        )
    }

    /// Re-materializes the loaded prefix against the post-change fetch result. That is O(loaded
    /// prefix), not O(library): the prefix is bounded by how far the user has scrolled, and
    /// `PHAsset` faults are cheap to create, so this stays flat regardless of library size.
    private func apply(_ change: PHChange) {
        guard let fetchResult, let details = change.changeDetails(for: fetchResult) else { return }
        let updated = details.fetchResultAfterChanges
        self.fetchResult = updated
        let update = Self.libraryChangeUpdate(
            loadedCount: videos.count,
            hasIncrementalChanges: details.hasIncrementalChanges,
            changedIdentifiers: { details.changedObjects.map(\.localIdentifier) }
        )
        videos = Self.prefix(of: updated, count: update.prefixCount)
        // Not `replaceVideos`: dropping the whole thumbnail cache on a content-only change — an
        // iCloud download finishing, a favorite toggle — would leave it empty until a tile next
        // appears, and no tile appears while the user is stationary.
        thumbnails.replaceAssets(videos, invalidating: update.invalidatedIdentifiers)
    }

    private func replaceVideos(with assets: [PHAsset]) {
        videos = assets
        thumbnails.reset()
    }

    private static func prefix(of result: PHFetchResult<PHAsset>, count: Int) -> [PHAsset] {
        let end = min(result.count, count)
        guard end > 0 else { return [] }
        return result.objects(at: IndexSet(integersIn: 0..<end))
    }

    // MARK: - Selection

    func isResolving(_ asset: PHAsset) -> Bool {
        resolution?.assetIdentifier == asset.localIdentifier
    }

    /// iCloud download progress for `asset`, or nil if it isn't the one being resolved or hasn't
    /// started downloading.
    func downloadProgress(for asset: PHAsset) -> Double? {
        isResolving(asset) ? resolution?.downloadProgress : nil
    }

    /// Resolves the tapped asset to a readable `AVURLAsset` and pushes it onto `path`. One at a
    /// time: tiles are disabled while a resolution is in flight, and `cancelSelection()` aborts it.
    func select(_ asset: PHAsset) {
        guard resolution == nil else { return }
        errorMessage = nil
        resolution = Resolution(assetIdentifier: asset.localIdentifier, downloadProgress: nil)

        resolveTask = Task {
            defer { resolution = nil }
            do {
                let identifier = asset.localIdentifier
                let avAsset = try await resolver.resolve(asset) { progress in
                    Task { @MainActor in
                        // A cancelled request can still emit a tick or two; don't let a stale one
                        // paint a download ring on whatever the user tapped next.
                        if self.resolution?.assetIdentifier == identifier {
                            self.resolution?.downloadProgress = progress
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                path.append(SelectedVideo(assetIdentifier: identifier, asset: avAsset, duration: asset.duration))
            } catch is CancellationError {
                // User backed out; nothing to report.
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelSelection() {
        resolveTask?.cancel()
    }
}

private extension UIApplication {
    /// The view controller to present the limited-library picker from: the foreground scene's
    /// key window root, following any presentation chain to the top.
    var topViewController: UIViewController? {
        let scene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
