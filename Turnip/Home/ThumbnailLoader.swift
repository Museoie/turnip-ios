import Photos
import UIKit

/// Owns the `PHCachingImageManager` behind the Home grid and keeps its cache warm around what the
/// user is looking at.
///
/// `PHCachingImageManager` caches nothing on its own — only assets handed to `startCachingImages`
/// are prefetched — so as tiles appear this re-centers a window of assets on the newest visible
/// index, starts caching what entered the window and stops caching what left it. Cache hits also
/// require the exact same size, content mode and options as the prefetch, which is why the tiles'
/// own requests go through here rather than straight to the manager.
@MainActor
final class ThumbnailLoader {
    /// Assets on each side of the newest visible tile to keep warm. At 3 columns and ~5 rows per
    /// screen this is a bit over a screen in each direction — enough to cover a flick, small enough
    /// that the decoded thumbnails stay in the tens of megabytes.
    static let prefetchRadius = 18

    private let manager: PHCachingImageManager
    private let options: PHImageRequestOptions
    private var cachedRange: Range<Int> = 0..<0
    private var cachedAssets: [PHAsset] = []
    /// The tile the window is centered on, kept so the window can be rebuilt against a new asset
    /// list without waiting for another tile to appear.
    private var center: Int?
    /// Learned from the first tile request. Tiles are uniform, so one size serves the whole grid.
    private var pixelSize: CGSize?
    /// Bumped for an asset whose content changed. A tile that is already on screen gets no second
    /// `onAppear` while the grid is stationary, so this counter is the only thing that can tell it
    /// the thumbnail it is showing is stale. Monotonic: `reset()` leaves it alone, because dropping
    /// the cache doesn't make an already-delivered image wrong.
    private var revisions: [String: Int] = [:]

    init(manager: PHCachingImageManager = PHCachingImageManager()) {
        self.manager = manager
        manager.allowsCachingHighQualityImages = false
        options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
    }

    static func pixelSize(for pointSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    /// Requests one tile's thumbnail. `handler` may be called twice under opportunistic delivery —
    /// a degraded image first, then the final one — and reports which it is.
    func requestImage(
        for asset: PHAsset, pixelSize: CGSize, handler: @escaping (UIImage?, _ isDegraded: Bool) -> Void
    ) -> PHImageRequestID {
        self.pixelSize = pixelSize
        return manager.requestImage(
            for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options
        ) { image, info in
            handler(image, (info?[PHImageResultIsDegradedKey] as? Bool) == true)
        }
    }

    func cancel(_ requestID: PHImageRequestID) {
        manager.cancelImageRequest(requestID)
    }

    /// A screen-sized poster frame for `asset`, aspect-fit into `pixelSize`: what Processing
    /// draws under its player until the first decoded frame arrives, and what its neighbor
    /// pages slide in with. One final-quality delivery rather than the tiles' opportunistic
    /// two, so a caller can await a single image; requested outside the caching window, since
    /// nothing else asks for this size. The result is also kept for `cachedPoster(for:)`.
    func poster(for asset: PHAsset, pixelSize: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let delivery = SingleDelivery()
        let image: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset, targetSize: pixelSize, contentMode: .aspectFit, options: options
            ) { image, _ in
                guard delivery.claim() else { return }
                continuation.resume(returning: image)
            }
        }
        if let image {
            recentPosters.removeAll { $0.identifier == asset.localIdentifier }
            recentPosters.append((asset.localIdentifier, image))
            if recentPosters.count > Self.recentPosterCount {
                recentPosters.removeFirst()
            }
        }
        return image
    }

    /// A poster `poster(for:pixelSize:)` delivered recently, available synchronously: the
    /// screen a swipe slides into place is a new view, and it draws this from its very first
    /// frame rather than showing black while it requests the same image again.
    func cachedPoster(for identifier: String) -> UIImage? {
        recentPosters.last { $0.identifier == identifier }?.image
    }

    /// Bounded small: the screens that need a poster back are one swipe apart.
    private static let recentPosterCount = 6
    private var recentPosters: [(identifier: String, image: UIImage)] = []

    /// How many times `asset`'s content has been invalidated. A tile reads this as a plain value
    /// and re-requests when it changes.
    func revision(for asset: PHAsset) -> Int {
        revisions[asset.localIdentifier] ?? 0
    }

    /// Tile `index` of `assets` just appeared: re-center the prefetch window on it.
    func tileAppeared(at index: Int, in assets: [PHAsset]) {
        center = index
        guard pixelSize != nil else { return }
        let range = Self.prefetchRange(around: index, count: assets.count, radius: Self.prefetchRadius)
        guard range != cachedRange else { return }
        moveWindow(to: range, in: assets, invalidating: [])
    }

    /// The asset list was replaced underneath the window without the user scrolling. Re-centers on
    /// the same tile and diffs by identifier, so a decode survives whether its asset stayed put or
    /// merely shifted index; `invalidated` identifiers are re-cached because their content changed.
    func replaceAssets(_ assets: [PHAsset], invalidating invalidated: Set<String>) {
        guard pixelSize != nil, let center else {
            // The window can only be rebuilt by the next `tileAppeared`, but a tile that is on
            // screen right now is showing the pre-change image and the counter is its only signal.
            for identifier in invalidated {
                revisions[identifier, default: 0] += 1
            }
            reset()
            return
        }
        let range = Self.prefetchRange(around: center, count: assets.count, radius: Self.prefetchRadius)
        moveWindow(to: range, in: assets, invalidating: invalidated)
    }

    /// The grid was reloaded from scratch (authorization change, limited-library reselection): drop
    /// the window entirely, since the next `tileAppeared` rebuilds it against the new list.
    func reset() {
        manager.stopCachingImagesForAllAssets()
        cachedRange = 0..<0
        cachedAssets = []
        center = nil
    }

    private func moveWindow(to range: Range<Int>, in assets: [PHAsset], invalidating invalidated: Set<String>) {
        guard let pixelSize else { return }
        let incoming = Array(assets[range])
        let incomingIDs = Set(incoming.map(\.localIdentifier))
        let currentIDs = Set(cachedAssets.map(\.localIdentifier))
        let toStop = cachedAssets.filter {
            !incomingIDs.contains($0.localIdentifier) || invalidated.contains($0.localIdentifier)
        }
        let toStart = incoming.filter {
            !currentIDs.contains($0.localIdentifier) || invalidated.contains($0.localIdentifier)
        }

        for asset in toStart where invalidated.contains(asset.localIdentifier) {
            revisions[asset.localIdentifier, default: 0] += 1
        }

        if !toStop.isEmpty {
            manager.stopCachingImages(for: toStop, targetSize: pixelSize, contentMode: .aspectFill, options: options)
        }
        if !toStart.isEmpty {
            manager.startCachingImages(for: toStart, targetSize: pixelSize, contentMode: .aspectFill, options: options)
        }
        cachedRange = range
        cachedAssets = incoming
    }

    /// The half-open index range to keep cached around `index`, clamped to `0..<count`.
    nonisolated static func prefetchRange(around index: Int, count: Int, radius: Int) -> Range<Int> {
        guard count > 0, radius >= 0 else { return 0..<0 }
        let center = min(max(index, 0), count - 1)
        let lower = max(0, center - radius)
        let upper = min(count, center + radius + 1)
        return lower..<upper
    }
}

/// Guards a continuation against a second result-handler call: PhotoKit documents one
/// delivery for `.highQualityFormat`, and a second resume would be a crash rather than a
/// stale image, so the contract is enforced here instead of trusted.
private final class SingleDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
