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

    var body: some View {
        NavigationStack(path: $viewModel.path) {
            content
                // The wordmark is scroll content (`HomeHeader`), not a bar title, so it
                // scrolls away with the tiles (docs/UIUX.md). Root-only — pushed screens
                // declare their own bars. `HomeNavigationBar` also places the filter and
                // settings controls — see its doc comment for why that placement differs
                // between iOS 26 and earlier.
                .modifier(HomeNavigationBar(viewModel: viewModel, showSettings: { showSettings = true }))
                .navigationDestination(for: SelectedVideo.self) { video in
                    // A video the camera already analyzed while recording it lands on the
                    // clip list directly. Otherwise the Processing screen shows the picked
                    // video and runs the real detection pipeline on the user's tap, then
                    // pushes the clip list on success — analysis never auto-starts
                    // (docs/UIUX.md § "Processing"). `popToRoot` threads the flow's "back
                    // to Home" action through the pushed screens so their back chevrons
                    // return here instead of stepping back through the flow.
                    if let clips = video.detectedClips {
                        clipList(for: video, clips: clips, asset: video.asset, popToRoot: popToRoot)
                    } else {
                        ProcessingView(
                            video: video,
                            runner: ProcessingPipeline(sampleRate: settings.analysisGranularity),
                            autostart: false,
                            popToRoot: popToRoot,
                            initialPoster: viewModel.thumbnails.cachedPoster(for: video.assetIdentifier),
                            poster: viewModel.asset(withIdentifier: video.assetIdentifier).map(posterLoader),
                            previous: browseNeighbor(of: video, offset: -1),
                            next: browseNeighbor(of: video, offset: 1),
                            // Renders this screen's browse-in-flight overlay from the same
                            // `Resolution` state `ResolutionBanner` already shows on the grid.
                            // Almost always the swipe this screen just triggered; showing it for
                            // the rare unrelated case too (a camera recording resolving in the
                            // background) is harmless — it just dims an already-paused video.
                            browsingNeighbor: viewModel.resolution,
                            cancelBrowsing: viewModel.cancelSelection,
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
                }
        }
        .task { await viewModel.start() }
        .alert("Couldn't open video", isPresented: errorPresented) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
    }

    private func popToRoot() {
        viewModel.path = []
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
            popToRoot: popToRoot
        )
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
            VideoGalleryView(viewModel: viewModel)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
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
    }

    private func tile(for asset: PHAsset, index: Int) -> some View {
        Button {
            viewModel.select(asset)
        } label: {
            VideoTileView(
                asset: asset,
                thumbnails: viewModel.thumbnails,
                revision: viewModel.thumbnails.revision(for: asset),
                isResolving: viewModel.isResolving(asset),
                downloadProgress: viewModel.downloadProgress(for: asset)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.resolution != nil)
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
