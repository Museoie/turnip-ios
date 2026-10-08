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
    /// progress callback — local assets resolve without ever setting it — and returns to nil when
    /// the composition-export phase starts, so both progress surfaces fall back to their
    /// indeterminate "Preparing video…" state for a phase that isn't a download. The phase is
    /// monotonic: once `.exporting` has landed, `isExporting` stays set and later `.downloading`
    /// events are dropped (see `apply(_:)`).
    struct Resolution: Equatable {
        let assetIdentifier: String
        var downloadProgress: Double?
        /// Set once the composition-export phase starts. Guards against a `.downloading` event
        /// arriving *after* `.exporting`: PhotoKit can report download progress for the export
        /// request itself — the same `PHVideoRequestOptions` carries its progress handler into
        /// `requestExportSession` — and the per-event `Task { @MainActor in }` hop has no
        /// ordering guarantee, so without this the banner could flip back to
        /// "Downloading from iCloud…" for the rest of the export.
        var isExporting = false

        /// Applies one progress event, keeping the phase monotonic: `.exporting` maps to nil —
        /// the determinate download bar must not linger at 100% through the composition export —
        /// and wins over any `.downloading` tick that arrives later, whichever order the `Task`
        /// hops land in. Nil is the state both progress surfaces already render as indeterminate
        /// "Preparing video…".
        mutating func apply(_ progress: ResolutionProgress) {
            switch progress {
            case .exporting:
                isExporting = true
                downloadProgress = nil
            case .downloading(let fraction) where !isExporting:
                downloadProgress = fraction
            case .downloading:
                break
            }
        }
    }

    /// How many assets to materialize per page. The grid only ever holds a prefix of the fetch
    /// result, so a library with thousands of videos costs the same on first load as one with 60.
    static let pageSize = 60
    /// Start loading the next page when the user is this many tiles from the end of the loaded
    /// prefix — a bit more than one screen at 3 columns, so the grid never visibly runs out.
    static let loadMoreThreshold = 18

    @Published private(set) var authorization: PhotoLibraryAuthorization
    /// The active gallery filter. Read by `reload()` to build the fetch, and by
    /// `GalleryFilterButton` to show which row is checked.
    @Published private(set) var filter: GalleryFilter = .all
    /// User albums (regular + shared, not smart albums — `.smartAlbum` is a separate
    /// `PHAssetCollectionType` and never appears here), for the filter menu's Album submenu.
    /// Re-fetched on every `reload()` (an album *list* fetch, cheap relative to a video fetch)
    /// rather than once and cached, so an album created or deleted in Photos is never stuck
    /// stale for the rest of the session — there's no library change observer wired to it
    /// separately (`observeLibraryChanges()` only watches `fetchResult`).
    @Published private(set) var albums: [PHAssetCollection] = []
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
    /// Navigation path of picked videos. A `SelectedVideo`'s lifetime here *is* its temp
    /// export's lifetime: `select()` resolves the tapped tile (possibly writing a composition
    /// export into tmp/), and when the element leaves the path the file must not linger —
    /// browsing back out without running the diagnostic is the dominant path, not an edge case.
    @Published var path: [SelectedVideo] = [] {
        didSet {
            for video in oldValue where !path.contains(video) {
                // Ordinary Photos videos point into the Photos container and this is a no-op
                // for them (`deleteTemporaryExport` discriminates on the tmp/ prefix); exports
                // are deleted the moment nothing references them anymore.
                PhotoVideoResolver.deleteTemporaryExport(for: video.asset)
            }
        }
    }

    /// Whether Home is showing (or about to show) its expanded destination — `path` non-empty
    /// once a video has resolved, `resolution` non-nil from the moment a tap/browse starts
    /// resolving one. `RootTabView` reads this (not `path.isEmpty` alone) to gate the page
    /// pager and floating tab bar: `HomeExpansionContainer`'s flight starts immediately on tap,
    /// before `path` has anything in it, and the pager must already be locked out by then.
    var isPresentingDestination: Bool {
        !path.isEmpty || resolution != nil
    }

    let thumbnails = ThumbnailLoader()

    private let library: PHPhotoLibrary
    private let resolver: PhotoVideoResolver
    private var fetchResult: PHFetchResult<PHAsset>?
    private var changeForwarder: PhotoLibraryChangeForwarder?
    private var resolveTask: Task<Void, Never>?

    /// `authorization` overrides the real `PHPhotoLibrary` read when non-nil — the screenshot
    /// harness's denied-state view needs a `GalleryFilterButton` wired to a real
    /// `VideoLibraryViewModel` (so `.disabled` is exercised by the same code path production
    /// uses, not a hand-duplicated stand-in), but reading the CI simulator's actual, un-prompted
    /// authorization status would make that harness state non-deterministic across simulator
    /// versions. Same seam shape as `library`/`resolver` above.
    init(
        library: PHPhotoLibrary = .shared(),
        resolver: PhotoVideoResolver = PhotoVideoResolver(),
        authorization: PhotoLibraryAuthorization? = nil
    ) {
        self.library = library
        self.resolver = resolver
        self.authorization =
            authorization ?? PhotoLibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
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
        options.predicate = filter.predicate
        let result: PHFetchResult<PHAsset>
        if case .album(let collection) = filter {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        fetchResult = result
        replaceVideos(with: Self.prefix(of: result, count: Self.pageSize))
        observeLibraryChanges()
        loadAlbums()
    }

    /// Applies a new gallery filter and reloads the grid against it. A no-op if `filter` is
    /// already the requested value — reselecting the current row shouldn't drop the loaded
    /// prefix and thumbnail cache for nothing.
    func selectFilter(_ filter: GalleryFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        reload()
    }

    /// User albums for the filter menu's Album submenu. Not gated on `authorization.canReadLibrary`
    /// beyond `reload()`'s own guard — `PHAssetCollection.fetchAssetCollections` only ever
    /// returns what this app can already see, `.limited` included, the same way the video fetch
    /// itself is silently scoped.
    private func loadAlbums() {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var collections: [PHAssetCollection] = []
        result.enumerateObjects { collection, _, _ in collections.append(collection) }
        // Sorted here, in Swift, rather than via a PHFetchOptions.sortDescriptors NSSortDescriptor
        // keyed on "localizedTitle" -- whether PhotoKit actually supports sorting a
        // PHAssetCollection fetch on that key is unverified, and nothing exercises this line in
        // CI (the screenshot harness never calls reload()/loadAlbums(), and the unit tests only
        // cover GalleryFilter's pure predicate) -- so a silently-ignored descriptor could ship
        // unnoticed. localizedStandardCompare is the same comparison Finder/Files use for names.
        albums = collections.sorted {
            ($0.localizedTitle ?? "").localizedStandardCompare($1.localizedTitle ?? "") == .orderedAscending
        }
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
        if Self.shouldLoadNextPage(tileIndex: index, loadedCount: videos.count) {
            loadNextPage()
        }
    }

    /// Whether a tile appearing at `tileIndex` is close enough to the end of the loaded prefix to
    /// grow it. Split out for the same reason as `libraryChangeUpdate`: the threshold arithmetic is
    /// the part worth pinning, and the rest of `tileAppeared(at:)` needs a live thumbnail cache.
    static func shouldLoadNextPage(tileIndex: Int, loadedCount: Int) -> Bool {
        tileIndex >= loadedCount - loadMoreThreshold
    }

    /// The next slice of a fetch result to materialize, or nil when `loadedCount` already covers
    /// everything there is. Both the first page and every later one go through here, so a fetch
    /// result is never asked for zero objects and the bound lives in one place.
    static func pageRange(loadedCount: Int, total: Int, pageSize: Int) -> Range<Int>? {
        let end = min(total, loadedCount + pageSize)
        guard end > loadedCount else { return nil }
        return loadedCount..<end
    }

    private func loadNextPage() {
        guard let fetchResult,
              let range = Self.pageRange(
                  loadedCount: videos.count, total: fetchResult.count, pageSize: Self.pageSize)
        else { return }
        videos.append(contentsOf: fetchResult.objects(at: IndexSet(integersIn: range)))
    }

    /// The slice of a fetch result that materializing up to `minimumCount` needs, capped at the
    /// library's real size — nil once the loaded prefix already reaches it. Unlike `pageRange`,
    /// the target is an arbitrary count rather than a fixed page size, so this covers any gap a
    /// caller asks for in one call; `browseToNeighbor(of:offset:)`, the only caller today, only
    /// ever asks for one asset past the loaded prefix.
    static func growthRange(loadedCount: Int, total: Int, minimumCount: Int) -> Range<Int>? {
        let end = min(total, minimumCount)
        guard end > loadedCount else { return nil }
        return loadedCount..<end
    }

    /// Materializes exactly enough of the fetch result to reach `minimumCount` —
    /// `browseToNeighbor(of:offset:)`'s on-demand counterpart to the grid's own page-at-a-time
    /// `loadNextPage()`, since a browse can ask for an index the grid hasn't scrolled to yet.
    private func growPrefix(toAtLeast minimumCount: Int) {
        guard let fetchResult,
              let range = Self.growthRange(
                  loadedCount: videos.count, total: fetchResult.count, minimumCount: minimumCount)
        else { return }
        videos.append(contentsOf: fetchResult.objects(at: IndexSet(integersIn: range)))
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
        guard let range = pageRange(loadedCount: 0, total: result.count, pageSize: count) else {
            return []
        }
        return result.objects(at: IndexSet(integersIn: range))
    }

    // MARK: - Selection

    func isResolving(_ asset: PHAsset) -> Bool {
        resolution?.assetIdentifier == asset.localIdentifier
    }

    /// iCloud download progress for `asset`, or nil if it isn't the one being resolved, hasn't
    /// started downloading, or has moved past the download into the composition-export phase.
    func downloadProgress(for asset: PHAsset) -> Double? {
        isResolving(asset) ? resolution?.downloadProgress : nil
    }

    /// Resolves the tapped asset to a readable `AVURLAsset` and pushes it onto `path`. One at a
    /// time: tiles are disabled while a resolution is in flight, and `cancelSelection()` aborts it.
    /// A composition export written during resolution lives as long as its `SelectedVideo` stays
    /// on `path` — see the property's `didSet`.
    ///
    /// `detectedClips` travels with the pushed video when the caller already has them — a take
    /// the camera scored while recording — and Home then lands on the clip list instead of
    /// Processing. A tapped tile has none.
    func select(_ asset: PHAsset, detectedClips: DetectedClips? = nil) {
        resolveAndInsert(asset, detectedClips: detectedClips, replacingTop: false)
    }

    /// Resolves `asset` and swaps it in for the current top of `path`, rather than pushing a new
    /// entry — Processing's swipe-to-browse between adjacent videos, so the back chevron still
    /// returns to Home in one step instead of walking back through every video swiped past.
    /// Returns whether a resolution started; `false` means one was already in flight.
    @discardableResult
    func browse(to asset: PHAsset) -> Bool {
        resolveAndInsert(asset, detectedClips: nil, replacingTop: true)
    }

    /// The loaded asset with this identifier, or nil once it has left the library (or never
    /// entered the grid — a take the camera just saved reaches `path` before the library change
    /// that lists it lands).
    func asset(withIdentifier identifier: String) -> PHAsset? {
        videos.first { $0.localIdentifier == identifier }
    }

    /// The neighbor at `offset` from `assetIdentifier` — `-1` for the one before it in the grid
    /// (`videos` is newest-first, so that's the chronologically newer video), `+1` for the one
    /// after (older) — or nil at that end of the grid. Read straight from the fetch result when
    /// it sits past the loaded prefix, so this reaches the whole library without growing
    /// `videos`: a pure read, safe to call from a view body. `browseToNeighbor(of:offset:)` is
    /// the mutating counterpart for when the swipe actually lands.
    func neighbor(of assetIdentifier: String, offset: Int) -> PHAsset? {
        guard let currentIndex = videos.firstIndex(where: { $0.localIdentifier == assetIdentifier })
        else { return nil }
        let total = fetchResult?.count ?? videos.count
        guard let index = Self.neighborIndex(currentIndex: currentIndex, offset: offset, count: total)
        else { return nil }
        return index < videos.count ? videos[index] : fetchResult?.object(at: index)
    }

    /// Resolves the neighbor at `offset` from `assetIdentifier` and browses to it, growing the
    /// loaded prefix first if it sits past what's currently materialized. Call only in response
    /// to user action (the swipe gesture), never from a view body: growing the prefix publishes
    /// into `videos`, which SwiftUI disallows from within a view update. Returns whether a
    /// resolution started, so the swipe that asked can tell a landing in progress from a no-op.
    @discardableResult
    func browseToNeighbor(of assetIdentifier: String, offset: Int) -> Bool {
        guard let currentIndex = videos.firstIndex(where: { $0.localIdentifier == assetIdentifier })
        else { return false }
        let candidate = currentIndex + offset
        if candidate >= videos.count {
            growPrefix(toAtLeast: candidate + 1)
        }
        guard let index = Self.neighborIndex(currentIndex: currentIndex, offset: offset, count: videos.count)
        else { return false }
        return browse(to: videos[index])
    }

    /// The index arithmetic behind `neighbor(of:offset:)` and `browseToNeighbor(of:offset:)`,
    /// split out as the reachable, testable seam — `videos` itself only comes from a live
    /// `PHFetchResult`.
    static func neighborIndex(currentIndex: Int, offset: Int, count: Int) -> Int? {
        let candidate = currentIndex + offset
        guard candidate >= 0, candidate < count else { return nil }
        return candidate
    }

    func cancelSelection() {
        resolveTask?.cancel()
    }

    /// Returns `false` without doing anything while another resolution is in flight.
    @discardableResult
    private func resolveAndInsert(
        _ asset: PHAsset, detectedClips: DetectedClips?, replacingTop: Bool
    ) -> Bool {
        guard resolution == nil else { return false }
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
                            // The phase is monotonic by construction: once `.exporting` has
                            // landed, a late `.downloading` tick must not flip the banner back
                            // to a determinate download bar for the rest of the export.
                            self.resolution?.apply(progress)
                        }
                    }
                }
                guard !Task.isCancelled else {
                    // The export finished but the task was cancelled before it lands: no
                    // `SelectedVideo` ever enters `path`, so the `didSet` cleanup never sees
                    // the file. Delete it here — ordinary Photos videos are a no-op.
                    PhotoVideoResolver.deleteTemporaryExport(for: avAsset)
                    return
                }
                if replacingTop, path.isEmpty {
                    // The screen this browse meant to replace is gone — the user backed out
                    // to Home while a neighbor was still resolving. Landing on `path.append`
                    // here would push that screen right back, so drop the result instead, the
                    // same as an ordinary cancellation.
                    PhotoVideoResolver.deleteTemporaryExport(for: avAsset)
                    return
                }
                let video = SelectedVideo(
                    assetIdentifier: identifier, asset: avAsset, duration: asset.duration,
                    detectedClips: detectedClips)
                if replacingTop {
                    path[path.count - 1] = video
                } else {
                    path.append(video)
                }
            } catch is CancellationError {
                // User backed out; nothing to report.
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        return true
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
