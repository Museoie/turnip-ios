import AVFoundation
import Photos
import SwiftUI

/// Home / Video Gallery per docs/UIUX.md: the entry screen *is* the video picker — a 3-column
/// grid of every video in the Photos library, newest first. Tapping a tile is the "pick" action.
/// The view model is owned by `RootTabView` (shared with the Camera tab, whose finished
/// recordings feed into the same `select(_:)` a tapped tile calls) rather than by this view.
struct HomeView: View {
    @ObservedObject var viewModel: VideoLibraryViewModel
    /// Plain reference, not `@ObservedObject`: this view never displays a setting's value,
    /// it only reads `analysisGranularity` at navigation time and hands the store to the
    /// sheet, which observes it directly. `@ObservedObject` here would re-run this view's
    /// whole body — including the video grid's `ForEach` — on every keystroke in the
    /// Settings sheet's album-name field, for a value this view never shows.
    private let settings = TurnipSettingsStore.shared
    @State private var showSettings = false
    /// Stable for the life of one tap-to-close cycle — its own `id` never changes even though
    /// the video showing inside it can (`VideoLibraryViewModel.browse()` replacing `path`'s top
    /// element while this cover is up). `HomeExpansionContainer`'s doc comment on why a cover
    /// bound directly to a changing video would re-slide on every browse.
    @State private var presentationSlot: HomePresentationSlot?
    /// Every visible tile's own frame, keyed by asset identifier — bubbled up from
    /// `VideoGalleryView`'s tiles via `VideoTileFramePreferenceKey` rather than threaded down,
    /// since a preference already climbs the view tree with no plumbing needed.
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var tileThumbnails: [String: UIImage] = [:]

    var body: some View {
        NavigationStack {
            content
                // The wordmark is scroll content (`HomeHeader`), not a bar title, so it
                // scrolls away with the tiles (docs/UIUX.md). Root-only — pushed screens
                // declare their own bars. `HomeNavigationBar` also places the filter and
                // settings controls — see its doc comment for why that placement differs
                // between iOS 26 and earlier.
                .modifier(HomeNavigationBar(viewModel: viewModel, showSettings: { showSettings = true }))
        }
        .onPreferenceChange(VideoTileFramePreferenceKey.self) { tileFrames = $0 }
        .task { await viewModel.start() }
        .alert("Couldn't open video", isPresented: errorPresented) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
        .fullScreenCover(item: $presentationSlot) { slot in
            expansion(for: slot)
        }
        // `select(_:)`/`browse(to:)` both land here, including the camera tab's own finished
        // recordings — which never went through a tile tap here, so nothing has created a
        // slot yet. Creates one lazily in that case, with no tile frame to fly from (the
        // container's own fallback centers a small square instead).
        .onChange(of: viewModel.path.isEmpty) { isEmpty in
            if isEmpty {
                presentationSlot = nil
            } else if presentationSlot == nil, let identifier = viewModel.path.last?.assetIdentifier {
                presentSlot(HomePresentationSlot(tappedAssetIdentifier: identifier))
            }
        }
        // The cover's own `dismiss()` (its reverse flight's final step) only clears
        // `presentationSlot`, the thing it's actually bound to — this is what cleans up the
        // rest of the selection state behind it once that happens.
        .onChange(of: presentationSlot?.id) { id in
            guard id == nil else { return }
            viewModel.path = []
            viewModel.cancelSelection()
        }
    }

    /// Sets `presentationSlot`, suppressing the system's own slide-up transition for the
    /// cover's appearance: `HomeExpansionContainer` plays its own flight from `progress = 0`,
    /// which renders identically to the tile still sitting there (now hidden, replaced by the
    /// container's own card at the same frame) — any extra system animation on top shows as
    /// the whole screen additionally sliding up from the bottom during the transition.
    /// `Transaction.disablesAnimations` alone left a residual slide visible (confirmed by
    /// frame-by-frame inspection of a screen recording — the cover's content only occupied the
    /// bottom portion of the screen for the first couple of frames, growing to fill it, with no
    /// trace of this container's own scrim over the gap at the top): that flag suppresses
    /// SwiftUI's own animation system, but apparently not the UIKit `present(animated:)` call
    /// that backs `fullScreenCover` underneath. `UIView.setAnimationsEnabled(false)` reaches
    /// that layer directly; it's re-enabled on the next run loop turn, after the presentation
    /// has already been issued.
    private func presentSlot(_ slot: HomePresentationSlot) {
        UIView.setAnimationsEnabled(false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presentationSlot = slot
        }
        DispatchQueue.main.async {
            UIView.setAnimationsEnabled(true)
        }
    }

    /// The video Processing's swipe reaches at `offset` (`-1` previous, `+1` next) — nil when
    /// `viewModel.neighbor` says there's nothing there, which is what makes the swipe give
    /// only a little at that end of the grid instead of wrapping around. `neighbor` is a pure
    /// read, safe to call here in the view body; the actual browse — which can grow
    /// `viewModel.videos`, a published mutation — happens only once the swipe lands.
    private func browseNeighbor(of video: SelectedVideo, offset: Int) -> BrowseNeighbor? {
        guard let asset = viewModel.neighbor(of: video.assetIdentifier, offset: offset) else { return nil }
        return BrowseNeighbor(
            poster: posterLoader(for: asset),
            browse: { viewModel.browseToNeighbor(of: video.assetIdentifier, offset: offset) })
    }

    private func posterLoader(for asset: PHAsset) -> PosterLoader {
        { pixelSize in await viewModel.thumbnails.poster(for: asset, pixelSize: pixelSize) }
    }

    private func clipList(
        for video: SelectedVideo, clips: [ProcessedClip], asset: AVURLAsset, popToRoot: @escaping () -> Void
    ) -> ClipListView {
        ClipListView(
            items: clips.map { ClipListItem(window: $0.window, cropRect: $0.cropRect) },
            asset: asset,
            assetIdentifier: video.assetIdentifier,
            duration: video.duration,
            showsNoTricksFound: clips.isEmpty,
            popToRoot: popToRoot
        )
    }

    /// The identifier the cover is currently showing: the resolved video once `path` has one,
    /// else whichever tile the slot was opened for (or, for a camera-originated slot with no
    /// tile tap behind it, nil — the container's fallback then stands in for both the source
    /// frame and the thumbnail).
    private func currentIdentifier(for slot: HomePresentationSlot) -> String? {
        viewModel.path.last?.assetIdentifier ?? slot.tappedAssetIdentifier
    }

    /// The cover's whole content: `HomeExpansionContainer`'s flying card/scrim, wrapping
    /// whichever of three states applies — still resolving, resolved onto Processing, or
    /// resolved straight onto the clip list (a video the camera already analyzed). All three
    /// read `viewModel` live, not a value captured at open time, so a browse mid-presentation
    /// (changing `path`'s top) updates the content in place rather than needing a new slot.
    private func expansion(for slot: HomePresentationSlot) -> some View {
        let identifier = currentIdentifier(for: slot)
        let container = HomeExpansionContainer(
            sourceFrame: { identifier.flatMap { tileFrames[$0] } },
            thumbnail: identifier.flatMap { tileThumbnails[$0] },
            content: { handlers in destinationContent(identifier: identifier, handlers: handlers) }
        )
        // Lets the grid show through the cover while the card/scrim animate —
        // `HomeExpansionContainer` draws its own opaque scrim at `progress`, so without
        // this the system's default opaque cover background would hide the grid the whole
        // flight is supposed to reveal. iOS 16.4+ only; earlier OSes keep the flight
        // animation but lose the reveal-through-flight.
        return Group {
            if #available(iOS 16.4, *) {
                container.presentationBackground(.clear)
            } else {
                container
            }
        }
    }

    /// One `NavigationStack` for the whole cover, mounted immediately when it appears rather
    /// than created fresh partway through (inside the `if let video = viewModel.path.last`
    /// branch) once the tapped video's async resolve lands. A `NavigationStack` is a real
    /// `UINavigationController`; creating one *mid-presentation* gave it a first UIKit layout
    /// pass (nav bar hidden, safe area settling) that animated into place instead of snapping —
    /// read from the outside as the whole page sliding up from the bottom, on top of (and
    /// independent from) this container's own card/scrim flight. Mounting it at `progress ≈ 0`
    /// — while `content(closeHandlers)` is still near-invisible behind the card — makes that
    /// first layout pass happen off-screen, and the resolve landing becomes an ordinary root-
    /// content swap inside an already-settled controller instead of the controller's own birth.
    @ViewBuilder
    private func destinationContent(
        identifier: String?, handlers: HomeExpansionCloseHandlers
    ) -> some View {
        NavigationStack {
            if let video = viewModel.path.last {
                if let clips = video.detectedClips {
                    clipList(for: video, clips: clips, asset: video.asset, popToRoot: handlers.onRequestClose)
                } else {
                    ProcessingView(
                        video: video,
                        runner: ProcessingPipeline(sampleRate: settings.analysisGranularity),
                        autostart: false,
                        popToRoot: handlers.onRequestClose,
                        initialPoster: viewModel.thumbnails.cachedPoster(for: video.assetIdentifier),
                        poster: viewModel.asset(withIdentifier: video.assetIdentifier).map(posterLoader),
                        previous: browseNeighbor(of: video, offset: -1),
                        next: browseNeighbor(of: video, offset: 1),
                        // Renders this screen's browse-in-flight overlay from the same
                        // `Resolution` state `ResolutionBanner` already shows on the grid.
                        // Almost always the swipe this screen just triggered; showing it
                        // for the rare unrelated case too (a camera recording resolving in
                        // the background) is harmless — it just dims an already-paused video.
                        browsingNeighbor: viewModel.resolution,
                        cancelBrowsing: viewModel.cancelSelection,
                        onRequestClose: handlers.onRequestClose,
                        dismissGestureHooks: .init(
                            onChanged: handlers.dismissTranslationChanged,
                            onEnded: handlers.dismissEnded,
                            onCancelled: handlers.dismissCancelled),
                        destination: { result, popToRoot in
                            clipList(for: video, clips: result.clips, asset: result.asset, popToRoot: popToRoot)
                        }
                    )
                    // Ties the screen's identity to the video it's showing: without this,
                    // browsing to a neighbor replaces `path`'s top element but SwiftUI can
                    // reuse the existing `ProcessingView`, leaving its `@StateObject` and
                    // player pointed at the video that just left.
                    .id(video.assetIdentifier)
                }
            } else {
                ResolvingDestination(
                    thumbnail: identifier.flatMap { tileThumbnails[$0] },
                    resolution: viewModel.resolution,
                    cancel: {
                        viewModel.cancelSelection()
                        handlers.onRequestClose()
                    })
                // Matches `ProcessingView`'s own bar state (`.toolbar(.hidden, for:
                // .navigationBar)`), so the swap from this to it never flips the bar
                // shown→hidden on top of the root-content swap.
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.authorization {
        case .notDetermined:
            // The system permission prompt is up; nothing useful to draw behind it.
            ProgressView()
        case .denied(let restricted):
            VStack(spacing: 0) {
                HomeHeader()
                PhotosAccessDeniedView(restricted: restricted)
            }
        case .authorized, .limited:
            VideoGalleryView(
                viewModel: viewModel,
                hiddenAssetIdentifier: presentationSlot.flatMap(currentIdentifier),
                onTileTapped: { asset, thumbnail in
                    presentSlot(HomePresentationSlot(tappedAssetIdentifier: asset.localIdentifier))
                    if let thumbnail {
                        tileThumbnails[asset.localIdentifier] = thumbnail
                    }
                    viewModel.select(asset)
                },
                onThumbnailLoaded: { identifier, image in
                    tileThumbnails[identifier] = image
                })
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

/// `HomeView`'s stable fullScreenCover identity — see its own `presentationSlot` doc comment.
private final class HomePresentationSlot: Identifiable {
    let id = UUID()
    let tappedAssetIdentifier: String
    init(tappedAssetIdentifier: String) {
        self.tappedAssetIdentifier = tappedAssetIdentifier
    }
}

/// The destination while a tapped tile's video is still resolving (PhotoKit fetch, possibly an
/// iCloud download) — Photos-faithful: the flight happens instantly on tap, onto this full-
/// screen poster-plus-progress state, rather than waiting for the resolve to finish before
/// showing any motion. Mirrors `ProcessingView.browsingOverlay`'s look, since this is the same
/// situation (a swipe or tap landed on a video that needs a moment) for the first video instead
/// of a neighbor.
private struct ResolvingDestination: View {
    let thumbnail: UIImage?
    let resolution: VideoLibraryViewModel.Resolution?
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            VStack(spacing: 12) {
                if let progress = resolution?.downloadProgress {
                    Text("Downloading from iCloud…")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    ProgressView(value: progress)
                        .tint(.white)
                } else {
                    Text("Preparing video…")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    ProgressView()
                        .tint(.white)
                }
                Button("Cancel", role: .cancel, action: cancel)
                    .tint(.white)
            }
            .padding(32)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// The settings entry point's pre-iOS 26 fallback: `HomeNavigationBar` hides the real
/// navigation bar outright on those OSes (no Liquid Glass to anchor a toolbar item to), so
/// this instead floats as a manually-styled corner overlay. On iOS 26 the settings button is
/// a real `ToolbarItem` in `HomeNavigationBar`'s toolbar instead — living inside the bar's own
/// hit-testing hierarchy rather than layered over it, and picking up the system's native
/// Liquid Glass bar-button styling for free.
///
/// Extracted to its own type, not a private computed property, so the DEBUG screenshot
/// harness composes the exact same view `HomeNavigationBar` does instead of a hand-built
/// duplicate that can drift from it.
struct HomeSettingsButton: View {
    let action: () -> Void

    var body: some View {
        ScrimIconButton(systemImage: "gearshape", accessibilityLabel: "Settings", action: action)
            .padding()
            .accessibilityIdentifier("settings-button")
    }
}

/// The gallery filter entry point: All Items / Favorites / a specific album. Dimmed and
/// disabled without library access, the same way `CameraCaptureView`'s `formatMenu` disables
/// itself while recording — there is nothing for it to filter, and a Favorites tap that
/// silently changes nothing would be worse than an unavailable control.
///
/// Placed by `HomeNavigationBar`, which picks the `Placement` for the OS: a real `ToolbarItem`
/// on iOS 26 (in the bar's own hit-testing hierarchy, native Liquid Glass styling applied
/// automatically) or a manually-styled corner overlay pre-26 (no system glass to anchor to,
/// same reasoning as `HomeSettingsButton`). Not `ScrimIconButton` for the overlay glyph:
/// `Menu`'s `label` closure needs a bare glyph rather than a nested `Button`, the same reason
/// `formatMenu` doesn't use it either — mirrors `ScrimIconButton`'s look so it still reads as
/// the same control family.
struct GalleryFilterButton: View {
    enum Placement {
        case toolbar
        case overlay
    }

    @ObservedObject var viewModel: VideoLibraryViewModel
    let placement: Placement

    var body: some View {
        Group {
            switch placement {
            case .toolbar:
                menu
            case .overlay:
                menu.padding()
            }
        }
        .opacity(viewModel.authorization.canReadLibrary ? 1 : 0.4)
        .disabled(!viewModel.authorization.canReadLibrary)
        .accessibilityLabel("Filter")
        // The filled-vs-outline glyph below is a purely visual signal; this carries the same
        // state into the accessibility tree, the same convention TrimSliderView's handles use
        // for a control whose state must never depend only on its shape.
        .accessibilityValue(viewModel.filter.label)
        .accessibilityIdentifier("gallery-filter-button")
    }

    private var menu: some View {
        Menu {
            filterRow(.all)
            filterRow(.favorites)
            if !viewModel.albums.isEmpty {
                Menu {
                    ForEach(viewModel.albums, id: \.localIdentifier) { album in
                        filterRow(.album(album))
                    }
                } label: {
                    checkableLabel(albumRowTitle, isSelected: isAlbumSelected)
                }
            }
        } label: {
            glyph
        }
    }

    @ViewBuilder
    private var glyph: some View {
        // .fill for an active (non-.all) filter -- the same outline/filled convention
        // Photos' own filter control and SF Symbols' own "selected" pattern use -- so a
        // filtered grid with real results (not just the zero-match empty state) still
        // shows that a filter is on. Without this the glyph is byte-identical whether 20
        // of 300 videos are showing or all of them are.
        let image = Image(systemName: viewModel.filter == .all
            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            .font(.body.weight(.semibold))
        switch placement {
        case .toolbar:
            // No manual background: the system paints the native Liquid Glass bar-button
            // circle behind a plain toolbar glyph, the same way `ClipEditorView`'s toolbar
            // buttons stay unstyled and let the bar do it.
            image
        case .overlay:
            image
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
        }
    }

    private func filterRow(_ filter: GalleryFilter) -> some View {
        Button {
            viewModel.selectFilter(filter)
        } label: {
            checkableLabel(filter.label, isSelected: viewModel.filter == filter)
        }
    }

    @ViewBuilder
    private func checkableLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var isAlbumSelected: Bool {
        if case .album = viewModel.filter { return true }
        return false
    }

    private var albumRowTitle: String {
        isAlbumSelected ? "Album: \(viewModel.filter.label)" : "Album"
    }
}

/// Home's title row: the "Turnip" wordmark image (mark + text baked into one asset), centered
/// in a nav-bar-height band. Scroll content (not a nav bar title) so it scrolls away with the
/// tiles like the rest of Home's header (docs/UIUX.md). Internal so the DEBUG screenshot
/// harness can render the denied state exactly as Home does.
struct HomeHeader: View {
    private static let logoHeight: CGFloat = 36
    private static let rowHeight: CGFloat = 44

    var body: some View {
        Image("TitleLogo")
            .resizable()
            .scaledToFit()
            .frame(height: Self.logoHeight)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            .accessibilityLabel("Turnip")
            .accessibilityAddTraits(.isHeader)
    }
}

/// The grid plus its decorations: a "select more" banner under limited access, and a bottom
/// banner with a cancel button while a tapped video is being fetched. An ordinary full-screen
/// scrollable grid, newest videos first — no landing/reveal state.
struct VideoGalleryView: View {
    @ObservedObject var viewModel: VideoLibraryViewModel
    /// The identifier of the video currently expanded (`HomeView.currentIdentifier(for:)`) —
    /// that tile hides rather than un-rendering, the same reasoning as `ClipListView`'s own
    /// `ClipCardView.isHidden`: `HomeExpansionContainer`'s flying card stands in at this tile's
    /// exact frame, so hiding avoids any grid reflow underneath it.
    let hiddenAssetIdentifier: String?
    /// Opens the expansion on this asset, passing its already-decoded thumbnail (nil if the
    /// tile hasn't finished its own first decode yet) so the presenter can fly open from
    /// exactly here without a second image request.
    let onTileTapped: (PHAsset, UIImage?) -> Void
    let onThumbnailLoaded: (String, UIImage) -> Void
    /// Mirrors what's been reported through `onThumbnailLoaded`, kept locally too so a tap can
    /// read the tapped tile's own thumbnail synchronously rather than round-tripping through
    /// `HomeView`'s copy.
    @State private var thumbnailCache: [String: UIImage] = [:]
    /// The identifier the grid last auto-scrolled to recenter, so the scroll-to-current-tile
    /// effect below can tell a tap's own initial resolve (skip — the tile's already on screen)
    /// from a real browse to a different one (recenter).
    @State private var lastScrolledIdentifier: String?

    private static let spacing: CGFloat = 2
    private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if viewModel.authorization == .limited {
                    LimitedAccessBanner(selectMore: viewModel.presentLimitedLibraryPicker)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let resolution = viewModel.resolution {
                    ResolutionBanner(resolution: resolution, cancel: viewModel.cancelSelection)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded {
            // Not yet the same thing as "no videos" — the first fetch hasn't run.
            VStack(spacing: 0) {
                HomeHeader()
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if viewModel.videos.isEmpty {
            VStack(spacing: 0) {
                HomeHeader()
                emptyState
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                // The header is scroll content, not chrome: it leads the grid and leaves the
                // screen with the first row.
                HomeHeader()
                LazyVGrid(columns: columns, spacing: Self.spacing) {
                    ForEach(
                        Array(viewModel.videos.enumerated()), id: \.element.localIdentifier
                    ) { index, asset in
                        tile(for: asset, index: index)
                    }
                }
                // The floating tab bar overlays this screen rather than reserving its own
                // safe-area space, so without this the bottom row would end up permanently
                // stuck underneath it.
                .padding(.bottom, FloatingTabBarMetrics.clearance)
            }
            // The grid announces its count when VoiceOver enters it — a VoiceOver user
            // otherwise has no sense of how many videos they're swiping through. The
            // ScrollView must be declared an accessibility container: a label on a
            // non-element container is never announced on entry.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(gridAccessibilityLabel)
            .accessibilityIdentifier("video-grid")
            .onChange(of: viewModel.path.last?.assetIdentifier) { identifier in
                guard let identifier else {
                    lastScrolledIdentifier = nil
                    return
                }
                defer { lastScrolledIdentifier = identifier }
                // Skip the very first landing (a tap's own initial resolve): that tile is
                // already on screen — it's why it was tappable — so recentering it here is
                // both needless and visible, since it fires the instant resolution completes,
                // which for a local video can be well before `HomeExpansionContainer`'s scrim
                // has covered enough of the grid to hide a full-width re-center jump. Only an
                // actual swipe-to-browse landing on a *different* tile (`lastScrolledIdentifier`
                // already set, to the previous video) needs the grid recentered on it — Photos
                // scrolls its grid the same way, behind the one-up, per the research this
                // feature was built from.
                guard lastScrolledIdentifier != nil else { return }
                withTransaction(Transaction(animation: nil)) {
                    scrollProxy.scrollTo(identifier, anchor: .center)
                }
            }
        }
    }

    private func tile(for asset: PHAsset, index: Int) -> some View {
        Button {
            onTileTapped(asset, thumbnailCache[asset.localIdentifier])
        } label: {
            VideoTileView(
                asset: asset,
                thumbnails: viewModel.thumbnails,
                revision: viewModel.thumbnails.revision(for: asset),
                isResolving: viewModel.isResolving(asset),
                downloadProgress: viewModel.downloadProgress(for: asset),
                onImageLoaded: { image in
                    guard let image else { return }
                    thumbnailCache[asset.localIdentifier] = image
                    onThumbnailLoaded(asset.localIdentifier, image)
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.resolution != nil)
        .opacity(asset.localIdentifier == hiddenAssetIdentifier ? 0 : 1)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: VideoTileFramePreferenceKey.self,
                    value: [asset.localIdentifier: proxy.frame(in: .global)])
            }
        )
        .onAppear { viewModel.tileAppeared(at: index) }
    }

    /// "1 video" / "N videos", announced on entering the grid. Kept as a separate property
    /// (rather than inline) so the singular/plural branch is visible and greppable.
    private var gridAccessibilityLabel: String {
        let count = viewModel.videos.count
        if count == 1 {
            return String(localized: "1 video")
        }
        return String(localized: "\(count) videos")
    }

    /// A filter matching nothing must not read as an empty library — a user with hundreds of
    /// videos and none favorited would otherwise see "No videos" / "Record a tricking session",
    /// which is simply false. Checked ahead of the access-driven branch below: a filter picked
    /// under `.limited` access can still be the reason nothing shows, not just the access level.
    @ViewBuilder
    private var emptyState: some View {
        if viewModel.filter != .all {
            StatusStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "No matches",
                message: "No videos match \"\(viewModel.filter.label)\"."
            ) {
                Button("Clear Filter") { viewModel.selectFilter(.all) }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                    .accessibilityIdentifier("clear-gallery-filter")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            StatusStateView(
                systemImage: "video.slash",
                title: viewModel.authorization == .limited ? "No videos selected" : "No videos",
                message: viewModel.authorization == .limited
                    ? "Turnip can only see the videos you choose. Select some to get started."
                    : "Record a tricking session, and it'll show up here."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LimitedAccessBanner: View {
    let selectMore: () -> Void

    var body: some View {
        HStack {
            Text("Turnip can only see the videos you've selected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select More…", action: selectMore)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("select-more-videos")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("limited-access-banner")
    }
}

private struct ResolutionBanner: View {
    let resolution: VideoLibraryViewModel.Resolution
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                if let progress = resolution.downloadProgress {
                    Text("Downloading from iCloud…")
                        .font(.subheadline)
                    ProgressView(value: progress)
                } else {
                    Text("Preparing video…")
                        .font(.subheadline)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .accessibilityIdentifier("cancel-video-resolution")
        }
        .padding()
        .background(.bar)
        .accessibilityIdentifier("resolution-banner")
    }
}

/// Denied / restricted empty state. There's no picker fallback once Home is the gallery, so the
/// only way forward is Settings — unless a restriction means Settings can't help either.
struct PhotosAccessDeniedView: View {
    let restricted: Bool

    var body: some View {
        StatusStateView(
            systemImage: "photo.on.rectangle.angled",
            title: "Turnip needs access to your videos",
            message: restricted
                ? "Photos access is restricted on this device, so Turnip can't show your videos."
                : "Turnip finds and trims tricks in recordings from your Photos library. "
                    + "Allow access in Settings to get started."
        ) {
            if !restricted, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                    .accessibilityIdentifier("open-settings")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("photos-access-denied")
    }
}

/// Home's nav bar: present, transparent, visually empty, and taking no space. On iOS 26 a
/// scroll view's top scroll-edge glass — the soft blur that keeps the status bar legible
/// over tiles scrolling beneath it — is only drawn by a navigation bar that has content,
/// and only blurs (rather than merely dimming) when that content is text. A hidden bar,
/// an empty title, `scrollEdgeEffectStyle` on the scroll view, and a `safeAreaBar`
/// standing in for the bar all leave the status bar dead sharp; a clear color or a
/// `hidden()` text as the principal item gets a dim gradient with no blur; a
/// whitespace title draws stray glyphs. A fully transparent title text is the
/// "content" that makes UIKit draw the real blur, with the bar's own background hidden
/// so nothing else shows. The bar still reserves its band
/// in the safe area, so the content gets that band back: it ignores the top safe area
/// and re-adds only the status bar's share as an inset. The wordmark header then sits
/// directly under the status bar at rest — in the grid and in the non-scrolling states
/// alike, so it doesn't jump when the grid replaces the loading state — and the glass
/// fades in over the band only once tiles scroll under it.
///
/// Also places the filter and settings controls, since where they can live depends on the
/// same OS split as the glass itself: on iOS 26 they're real `ToolbarItem`s in this same bar
/// — at the title's level at rest, riding the bar's own scroll-edge glass once scrolled, and
/// reachable because they're part of the bar's hit-testing hierarchy rather than layered over
/// it. Pre-26 the bar is hidden outright (no glass to anchor a toolbar item to), so they fall
/// back to a manually-styled corner overlay instead. Internal so the DEBUG screenshot harness
/// and previews match.
struct HomeNavigationBar: ViewModifier {
    /// The inline bar's height on iOS 26 (measured: the top safe area with the bar minus
    /// the top safe area without it). There is no public constant for it.
    private static let barHeight: CGFloat = 54

    @ObservedObject var viewModel: VideoLibraryViewModel
    let showSettings: () -> Void

    /// Whether the scroll content has moved up past its rest position. With the header
    /// sitting inside the bar's band at rest, UIKit considers the content "under the
    /// bar" from the start and would draw the glass over the wordmark before any scroll;
    /// the effect is held hidden until the content actually moves.
    @State private var isScrolled = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GeometryReader { proxy in
                content
                    // A GeometryReader lays its child out top-leading; filling it keeps a
                    // lone spinner (the not-yet-determined state) centered.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: max(proxy.safeAreaInsets.top - Self.barHeight, 0))
                    }
                    .ignoresSafeArea(.container, edges: .top)
            }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 0.5
                } action: { _, scrolled in
                    isScrolled = scrolled
                }
                .scrollEdgeEffectHidden(!isScrolled, for: .top)
                // Inline, or the root bar lays out for a large title and reserves that
                // band too.
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        // The wordmark header already announces "Turnip" as the screen's
                        // header, so this stays out of the accessibility tree.
                        Text("Turnip")
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        GalleryFilterButton(viewModel: viewModel, placement: .toolbar)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: showSettings) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings-button")
                    }
                }
        } else {
            content
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .topLeading) {
                    GalleryFilterButton(viewModel: viewModel, placement: .overlay)
                }
                .overlay(alignment: .topTrailing) {
                    HomeSettingsButton(action: showSettings)
                }
        }
    }
}

#Preview("Denied") {
    NavigationStack {
        VStack(spacing: 0) {
            HomeHeader()
            PhotosAccessDeniedView(restricted: false)
        }
        .modifier(HomeNavigationBar(
            viewModel: VideoLibraryViewModel(authorization: .denied(restricted: false)),
            showSettings: {}))
    }
    .preferredColorScheme(.dark)
}

#Preview("Restricted") {
    NavigationStack {
        VStack(spacing: 0) {
            HomeHeader()
            PhotosAccessDeniedView(restricted: true)
        }
        .modifier(HomeNavigationBar(
            viewModel: VideoLibraryViewModel(authorization: .denied(restricted: true)),
            showSettings: {}))
    }
    .preferredColorScheme(.dark)
}
