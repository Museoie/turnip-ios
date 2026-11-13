import Photos
import SwiftUI

/// Which of the app's root pages is showing, in the order the tab bar draws its icons — left to
/// right, or top to bottom down the vertical bar — and the order `RootTabView`'s `TabView`
/// declares the pages: swiping right from Home reaches the Profile, the same way tapping its icon
/// does.
enum MainTab: Hashable {
    case profile
    case home

    /// The page the app opens on: the Profile once `library` holds a saved clip, since a
    /// returning user's training log is what they come back to, and the gallery before that, since
    /// a new user's first step is a video and the Profile has nothing to show yet.
    @MainActor
    static func landing(for library: ClipLibrary) -> MainTab {
        library.clips.isEmpty ? .home : .profile
    }

    /// The tab bar's accessibility identifier for this tab. The home tab's is "tab-videos": it
    /// names what the tab shows, not the enum case, and UI tests drive it.
    var accessibilityIdentifier: String {
        switch self {
        case .profile: return "tab-profile"
        case .home: return "tab-videos"
        }
    }
}

/// The floating bar's approximate footprint, shared with `VideoGalleryView` (grid scroll room) and
/// `ProfileView` so each can reserve clearance for the bar — it overlays their content rather than
/// pushing it up, so without this their bottom-most content would be permanently stuck underneath
/// it.
enum FloatingTabBarMetrics {
    static let clearance: CGFloat = 100
}

extension View {
    /// Keeps a root page's last content scrollable out from under the floating tab bar, which
    /// overlays the page rather than reserving space for itself: applied to whichever view ends the
    /// page, so `applies` is false on one that only sometimes does. Nothing when the tab bar sits
    /// in the vertical bar beside the page instead (`VerticalBar`).
    func floatingTabBarClearance(_ applies: Bool = true) -> some View {
        modifier(FloatingTabBarClearance(applies: applies))
    }
}

private struct FloatingTabBarClearance: ViewModifier {
    let applies: Bool
    @Environment(\.rootControlsInVerticalBar) private var inVerticalBar

    func body(content: Content) -> some View {
        content.padding(.bottom, applies && !inVerticalBar ? FloatingTabBarMetrics.clearance : 0)
    }
}

/// The app's root screen: a swipeable, two-page `TabView` (the Profile, then the gallery) with a
/// custom floating pill replacing the system tab bar, which would dock at the bottom and draw a
/// label under every icon. The camera isn't a page: the gallery's first tile opens it, sliding up
/// over everything.
///
/// On iPhone Duo the pager stays inside the safe area beside the system's vertical bar, and the
/// tab bar and Home's filter and settings controls move into that column (`VerticalBar`). A page
/// `TabView` laid across a side inset scrolls each page to its center *inside* the inset — half
/// the vertical bar's width short of the page — which opened the app stuck partway into a swipe.
///
/// Owns the one `VideoLibraryViewModel` shared by the camera and Home, since a finished camera
/// recording needs to hand its asset to the same gallery/navigation state a tapped tile would
/// (`VideoLibraryViewModel.select(_:)`). Owns the Profile's navigation path too, since whether a
/// Profile screen is pushed decides the pager's swipe and the bar's visibility here, and the
/// Settings sheet, since the vertical bar's settings button opens it from outside Home.
struct RootTabView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    /// The camera's session, pose model and picked lens and format, kept for the launch while the
    /// camera screen itself comes and goes (`CameraCaptureView.viewModel`). Held, not observed: it
    /// publishes the live pose many times a second while recording, which only the camera screen
    /// draws, and observing it here would re-run this whole body, pages included, at that rate.
    /// The screen starts the session as it appears, and this view stops it as the camera closes.
    @State private var camera = CameraCaptureViewModel()
    @State private var selectedTab: MainTab
    @State private var profilePath: [ProfileRoute] = []
    @State private var showsCamera = false
    @State private var showsSettings = false
    @State private var recordingSaveError: String?

    init() {
        _selectedTab = State(initialValue: MainTab.landing(for: .shared))
    }

    /// The page swipe belongs to the pages' roots alone. While Home presents a destination
    /// (`viewModel.isPresentingDestination`, true from the tap on), the Profile has a screen pushed,
    /// or the camera is up, that screen owns its own horizontal gestures — Processing browses
    /// videos with one, Needs a name pages clips with one — and the pager's recognizer would
    /// otherwise take every one of them first. Every page's lock writes this same value to the one
    /// pager, so no page can switch it back on under another.
    private var swipeEnabled: Bool {
        !viewModel.isPresentingDestination && profilePath.isEmpty && !showsCamera
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let verticalBar = VerticalBar(safeAreaInsets: insets)
            ZStack(alignment: verticalBar?.edge == .leading ? .topLeading : .topTrailing) {
                pager
                    .environment(\.rootControlsInVerticalBar, verticalBar != nil)
                    // Inside the side insets, so the pager's paging scroll view has none to center
                    // its pages in: on iPhone Duo the vertical bar's 84 pt would otherwise leave
                    // every page 42 pt short of where a swipe settles. No side insets on any other
                    // iPhone held upright, so this changes nothing there.
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                if let verticalBar, swipeEnabled {
                    VerticalBarControls(
                        selectedTab: selectedTab,
                        viewModel: viewModel,
                        bottomInset: insets.bottom,
                        openSettings: { showsSettings = true },
                        onSelect: slide(to:))
                    .frame(width: verticalBar.width)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .background(Color.black)
            // Hands the full window to the pages, top to bottom. A page-style `TabView` laid out
            // inside the safe area never gives its nested `NavigationStack` a top inset, and its
            // scroll views stop at the status bar instead of running under it; ignoring the safe
            // area here lets each page's own hosting controller get the real insets back from
            // UIKit, so nav bars and `.safeAreaInset` content stay put. The container's insets
            // only: the pages' hosting controllers get no keyboard inset back, so the keyboard's
            // room has to come from here, or a screen the Profile pushes types under it.
            .ignoresSafeArea(.container)
            // An overlay, not a safe-area inset: the grid scrolls underneath it rather than
            // stopping short, so it reads as floating over the content instead of a docked bar.
            // Visible on every page's root so its selection marker actually has something to slide
            // between. Hidden once Home drills into Processing/Name Clips/the editor, the Profile
            // pushes a screen or the camera is up, each of which has its own way back and needs the
            // full screen — and on iPhone Duo, where the vertical bar holds it instead.
            .overlay(alignment: .bottom) {
                if verticalBar == nil, swipeEnabled {
                    FloatingTabBar(selectedTab: selectedTab, axis: .horizontal, onSelect: slide(to:))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: swipeEnabled)
            .accessibilityHidden(showsCamera)
            .overlay {
                if showsCamera {
                    CameraCaptureView(viewModel: camera, onFinished: handleRecorded, onCancel: closeCamera)
                        // The whole window's height, not this overlay's: the camera's black
                        // reaches under the status bar and the home indicator, and a move by the
                        // safe area's height alone would leave that strip showing.
                        .transition(.offset(y: proxy.size.height + insets.top + insets.bottom))
                }
            }
        }
        // Stopped here as the camera closes, not by the closing screen's `onDisappear`: that fires
        // once its slide-down ends, and a camera opened again meanwhile is a new screen on the same
        // session, which the old one's late stop would freeze under it.
        .onChange(of: showsCamera) { isShown in
            if !isShown {
                camera.stop()
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(settings: TurnipSettingsStore.shared)
        }
        // A distinct alert from Home's "Couldn't open video" — that one is about
        // resolving an existing library asset, not about this just-recorded file
        // failing to save. Sharing it would misname the failure to the user.
        .errorAlert("Couldn't Save Recording", message: $recordingSaveError)
    }

    private var pager: some View {
        TabView(selection: $selectedTab) {
            ProfileView(library: .shared, vocabulary: .shared, path: $profilePath)
                .background(PageSwipeLock(swipeEnabled: swipeEnabled))
                .tag(MainTab.profile)
            HomeView(
                viewModel: viewModel,
                openCamera: openCamera,
                openSettings: { showsSettings = true })
                .background(PageSwipeLock(swipeEnabled: swipeEnabled))
                .tag(MainTab.home)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Slides the camera up over the gallery, from the gallery's camera tile.
    private func openCamera() {
        withAnimation(.easeInOut(duration: 0.3)) {
            showsCamera = true
        }
    }

    /// Slides the camera back down, from its cancel chevron.
    private func closeCamera() {
        withAnimation(.easeInOut(duration: 0.3)) {
            showsCamera = false
        }
    }

    /// A recording finished: save it to Photos (reusing the same `ClipPhotosSaver` the
    /// export flow already uses), then hand the resulting `PHAsset` to `viewModel.select`
    /// — the call a tapped gallery tile makes, plus the clips the camera detected live —
    /// and drop the camera so the user sees the pick land, Photos-app style.
    ///
    /// The temp file is only removed once it's safely in Photos — deleting it
    /// unconditionally (e.g. in a `defer`) would destroy the user's only copy of the
    /// footage if the save fails, such as when Photos access is denied.
    ///
    /// Saved with no album regardless of the Settings screen's "Save to an album" option: this
    /// is the raw, unanalyzed take (it becomes Clip List's "original" tile, not one of the
    /// derived clips), and the setting's own copy ("Save to an album" / a *saved clip*) means
    /// the curated exports `ClipListViewModel.save()` produces, not the source recording.
    private func handleRecorded(_ recording: CameraRecording) {
        Task {
            do {
                let identifier = try await ClipPhotosSaver().saveVideo(at: recording.fileURL)
                try? FileManager.default.removeItem(at: recording.fileURL)
                guard let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier], options: nil
                ).firstObject else { return }
                // Instant, unlike `closeCamera()` and `slide(to:)`: `select` opens the expansion
                // cover over Home in this same update, and a camera still sliding away, or a page
                // still sliding in, underneath it would hand the cover's flight a moving backdrop.
                showsCamera = false
                selectedTab = .home
                viewModel.select(
                    asset, detectedClips: recording.detectedClips, partialPose: recording.partialPose)
            } catch {
                recordingSaveError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Pages to `tab` the way a swipe does. A control that leads to another page plays the
    /// same slide the page swipe plays (docs/UIUX.md, "A gesture and its button play one
    /// animation"); the page `TabView` only scrolls to a selection that changes inside an
    /// animated transaction and otherwise cuts straight to it.
    private func slide(to tab: MainTab) {
        withAnimation {
            selectedTab = tab
        }
    }

}

/// The root pages' controls in the vertical bar's column on iPhone Duo (`VerticalBar`), stacked the
/// way the system stacks its own bar items there: the page's controls at the top, under the status
/// bar, and the tab bar at the foot. Home's are the filter and settings controls its nav bar holds
/// on any other iPhone; the Profile has none, so its column holds the tab bar alone.
private struct VerticalBarControls: View {
    let selectedTab: MainTab
    @ObservedObject var viewModel: VideoLibraryViewModel
    /// The window's bottom safe-area inset, kept clear under the tab bar.
    let bottomInset: CGFloat
    let openSettings: () -> Void
    let onSelect: (MainTab) -> Void

    /// The least room under the tab bar, on a display with no bottom inset.
    private static let minimumBottomPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 12) {
            if selectedTab == .home {
                GalleryFilterButton(viewModel: viewModel, placement: .verticalBar)
                    .transition(.opacity)
                HomeSettingsButton(action: openSettings)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            FloatingTabBar(selectedTab: selectedTab, axis: .vertical, onSelect: onSelect)
        }
        .padding(.top, VerticalBar.controlsTop)
        .padding(.bottom, max(bottomInset, Self.minimumBottomPadding))
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
    }
}

/// The floating tab bar: the Profile, then the gallery grid. A custom capsule rather than
/// `TabView`'s own bar, which docks at the bottom and labels every icon.
private struct FloatingTabBar: View {
    let selectedTab: MainTab
    /// Across the bottom of the screen, or down the vertical bar's column on iPhone Duo: the same
    /// pill turned a quarter turn, as the system turns its own tab bar there.
    let axis: Axis
    /// Pages to the tapped tab. The bar never writes the selection itself, so a tap can't
    /// skip the slide a swipe to the same page plays.
    let onSelect: (MainTab) -> Void
    /// Ties the selection pill to whichever icon is currently selected: only one of the
    /// `tabButton`s ever draws it (see `indicator`), so a change in `selectedTab`
    /// reads to SwiftUI as that same shape flying from its old spot to its new one
    /// rather than one fading out while an unrelated one fades in.
    @Namespace private var glassNamespace

    private static let spacing: CGFloat = 40

    var body: some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: Self.spacing))
            : AnyLayout(VStackLayout(spacing: Self.spacing))
        // The long side gets the wide padding whichever way the pill runs.
        let alongBar: Edge.Set = axis == .horizontal ? .horizontal : .vertical
        let acrossBar: Edge.Set = axis == .horizontal ? .vertical : .horizontal
        let buttons = layout {
            tabButton(.profile, systemImage: "person.crop.circle.fill", label: "Profile")
            tabButton(.home, systemImage: "square.grid.2x2.fill", label: "Videos")
        }
        .padding(alongBar, 28)
        .padding(acrossBar, 8)
        // Drives the indicator's slide for every path to a selection change alike — a
        // tap or a swipe of the page `TabView` — overriding whatever transaction the change
        // arrived in, so the pill moves the same way for both.
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedTab)

        // Real Liquid Glass where the OS supports it (iOS 26+); `.ultraThinMaterial`
        // otherwise, matching how the bar already looked pre-Liquid Glass.
        Group {
            if #available(iOS 26.0, *) {
                buttons.glassEffect()
            } else {
                buttons.background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    /// `label` stays a `LocalizedStringKey` so the call-site literals localize: a
    /// `String` parameter would pass the stored value through to `.accessibilityLabel(_:)`,
    /// which resolves to the non-localizing `StringProtocol` overload. The accessibility
    /// identifier derives from the tab, not the label — the home tab's is "tab-videos",
    /// naming what the tab shows rather than the enum case, and UI tests drive it.
    private func tabButton(_ tab: MainTab, systemImage: String, label: LocalizedStringKey) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            onSelect(tab)
        } label: {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.4))
                .frame(width: 44, height: 44)
                .background {
                    if isSelected {
                        indicator
                    }
                }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    /// The selected tab's pill. A plain translucent fill, not a second `.glassEffect` —
    /// stacking glass on glass artifacts, and the outer capsule is already real Liquid
    /// Glass on iOS 26. `matchedGeometryEffect` is what makes it slide: SwiftUI treats
    /// the copy that disappears from the old tab and the one that appears on the new tab
    /// (same `id`, same `Namespace`) as one shape in flight rather than a cross-fade.
    private var indicator: some View {
        Circle()
            .fill(.white.opacity(0.2))
            .matchedGeometryEffect(id: "tab-indicator", in: glassNamespace)
    }
}
