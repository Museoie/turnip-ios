import Photos
import SwiftUI

/// One square cell in the Home grid: cached thumbnail, duration badge, and — while this tile's
/// video is being fetched — a progress overlay (a determinate ring during an iCloud download, a
/// spinner otherwise).
///
/// Inputs are deliberately narrow (`isResolving` / `downloadProgress` rather than the whole
/// in-flight resolution) so an iCloud progress tick only invalidates the tile that is downloading.
struct VideoTileView: View {
    let asset: PHAsset
    let thumbnails: ThumbnailLoader
    /// Changes when this asset's content changed in Photos. The grid keys tiles on
    /// `localIdentifier`, which survives an edit, so the view keeps its `@State image` across the
    /// change and this is the only signal that the image is stale.
    let revision: Int
    let isResolving: Bool
    let downloadProgress: Double?

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    /// True while `image` is the low-quality first delivery. A tile that scrolls away before the
    /// final image arrives must be allowed to request again when it comes back.
    @State private var imageIsDegraded = false
    @State private var requestID: PHImageRequestID?
    /// The revision the image on screen was decoded for. A replacement request that is cancelled
    /// before it delivers leaves an image that is stale but looks final, so the appearance path has
    /// to stay open until this catches up with `revision`.
    @State private var loadedRevision = 0
    /// Identifies the request whose delivery is allowed to write state. A cancelled request still
    /// calls its handler, and that late callback must not touch what a newer request now owns.
    @State private var requestToken = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.secondarySystemFill)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear { load(targetSize: proxy.size) }
            .onChange(of: revision) { _ in load(targetSize: proxy.size, replacingCurrentImage: true) }
            .onDisappear(perform: cancel)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) { durationBadge }
        .overlay { if isResolving { resolvingOverlay } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    private var durationBadge: some View {
        Text(VideoDurationFormatter.string(from: asset.duration))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(4)
    }

    private var resolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
            if let downloadProgress {
                ProgressRing(progress: downloadProgress)
                    .frame(width: 36, height: 36)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
    }

    private var accessibilityDescription: String {
        var parts = ["Video", VideoDurationFormatter.string(from: asset.duration)]
        if let creationDate = asset.creationDate {
            parts.append(creationDate.formatted(date: .abbreviated, time: .shortened))
        }
        if isResolving {
            parts.append("loading")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Thumbnail loading

    // Every parameter is one piece of tile state the decision reads; grouping them behind a struct
    // would move the same six values without reducing what a caller supplies.
    // swiftlint:disable function_parameter_count
    /// Whether a request should be issued for a tile in this state.
    ///
    /// The invariant is that the appearance path stays open until a final delivery for the current
    /// revision has landed — an image left over from an earlier revision looks indistinguishable
    /// from a finished one, and nothing else would ever replace it.
    static func shouldRequestImage(
        hasImage: Bool,
        imageIsDegraded: Bool,
        hasRequestInFlight: Bool,
        loadedRevision: Int,
        revision: Int,
        replacingCurrentImage: Bool
    ) -> Bool {
        if replacingCurrentImage {
            return true
        }
        if hasRequestInFlight {
            return false
        }
        return !hasImage || imageIsDegraded || loadedRevision != revision
    }
    // swiftlint:enable function_parameter_count

    /// Whether a delivery puts the requested revision on screen. A final callback that carried no
    /// image — a failed iCloud fetch, say — ends the request without changing what is drawn, so the
    /// revision on screen is still the previous one and the appearance path has to stay open.
    static func deliveryLoadsRevision(hasResult: Bool, isDegraded: Bool) -> Bool {
        hasResult && !isDegraded
    }

    /// `replacingCurrentImage` re-requests over a final image, which the appearance path must never
    /// do; the old image stays on screen until the new decode lands, rather than flashing empty.
    private func load(targetSize: CGSize, replacingCurrentImage: Bool = false) {
        guard Self.shouldRequestImage(
            hasImage: image != nil,
            imageIsDegraded: imageIsDegraded,
            hasRequestInFlight: requestID != nil,
            loadedRevision: loadedRevision,
            revision: revision,
            replacingCurrentImage: replacingCurrentImage
        ) else { return }
        if replacingCurrentImage {
            cancel()
        }
        let pixelSize = ThumbnailLoader.pixelSize(for: targetSize, scale: displayScale)

        requestToken += 1
        let token = requestToken
        let requestedRevision = revision
        var finished = false
        let id = thumbnails.requestImage(for: asset, pixelSize: pixelSize) { result, isDegraded in
            guard token == requestToken else { return }
            // Opportunistic delivery may call back twice (degraded, then final); keep whichever is latest.
            if let result {
                image = result
                imageIsDegraded = isDegraded
            }
            if Self.deliveryLoadsRevision(hasResult: result != nil, isDegraded: isDegraded) {
                loadedRevision = requestedRevision
            }
            if !isDegraded {
                finished = true
                requestID = nil
            }
        }
        // A cache hit delivers the final image synchronously, before `requestImage` returns; don't
        // record an ID for a request that has already finished.
        if !finished {
            requestID = id
        }
    }

    private func cancel() {
        if let requestID {
            thumbnails.cancel(requestID)
        }
        requestID = nil
        requestToken += 1
    }
}

/// iOS has no determinate circular `ProgressView` style, so draw one.
private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
    }
}
