import Photos
import SwiftUI

/// Which of the app's two pages is showing. Camera sorts first only because that's the
/// order the floating tab bar draws its icons in, left to right, and the order the pages
/// are declared in `RootTabView`'s `TabView` — swiping right from Home (its previous page)
/// reaches Camera the same way tapping the camera icon does.
enum MainTab: Hashable {
    case camera
    case home
}

/// The floating bar's approximate footprint, shared with `VideoGalleryView` (grid scroll
/// room) and `CameraCaptureView` (record button/lens row spacing) so each can reserve
/// clearance for the bar — it overlays their content rather than pushing it up, so without
/// this their bottom-most controls would be permanently stuck underneath it.
enum FloatingTabBarMetrics {
    static let clearance: CGFloat = 100
}

/// The app's root screen: a swipeable, two-page `TabView` (Camera,
/// then the gallery) with a custom floating pill replacing the system tab bar — this app
/// has exactly two destinations, not the several a real `UITabBar` assumes.
///
/// Owns the one `VideoLibraryViewModel` shared by both pages, since a finished camera
/// recording needs to hand its asset to the same gallery/navigation state a tapped tile
/// would (`VideoLibraryViewModel.select(_:)`), and switching back to the gallery tab to
/// show that pick land needs to live somewhere both pages are reachable from.
struct RootTabView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    @State private var selectedTab: MainTab = .home
    @State private var recordingSaveError: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            CameraCaptureView(onFinished: handleRecorded, onCancel: { slide(to: .home) })
                .tag(MainTab.camera)
            HomeView(viewModel: viewModel)
                // The Camera/Home swipe belongs to Home's root alone. While Home presents
                // a destination (`viewModel.isPresentingDestination`, true from the tap on),
                // that screen owns its own horizontal gestures — Processing browses videos
                // with one — and the pager's
                // recognizer would otherwise take every one of them first.
                .background(PageSwipeLock(swipeEnabled: !viewModel.isPresentingDestination))
                .tag(MainTab.home)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // A page-style `TabView` lays its pages out inside the safe area, so the nested
        // `NavigationStack` never receives a top inset and its scroll views stop at the
        // status bar instead of running under it. Ignoring the safe area here hands the
        // full window to the pages; each page's own hosting controller then gets the real
        // insets back from UIKit, so nav bars and `.safeAreaInset` content stay put.
        .ignoresSafeArea()
        // An overlay, not a safe-area inset: the grid scrolls underneath it rather than
        // stopping short, so it reads as floating over the content instead of a docked
        // bar. Visible on both pages (root-only, `!viewModel.isPresentingDestination`) so its
        // selection marker actually has something to slide between — it's the reason a
        // tab bar's marker animates in Slack/Instagram-style apps at all. Hidden only
        // once Home drills into Processing/ClipList/ClipEditor, each of which has its own
        // back chevron and needs the full screen; Camera keeps its own cancel chevron too,
        // so the bar there is an additional way back, not a replacement.
        .overlay(alignment: .bottom) {
            if !viewModel.isPresentingDestination {
                FloatingTabBar(selectedTab: selectedTab, onSelect: slide(to:))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isPresentingDestination)
        // A distinct alert from Home's "Couldn't open video" — that one is about
        // resolving an existing library asset, not about this just-recorded file
        // failing to save. Sharing it would misname the failure to the user.
        .errorAlert("Couldn't Save Recording", message: $recordingSaveError)
    }

    /// A recording finished: save it to Photos (reusing the same `ClipPhotosSaver` the
    /// export flow already uses), then hand the resulting `PHAsset` to `viewModel.select`
    /// — the call a tapped gallery tile makes, plus the clips the camera detected live —
    /// and switch to the gallery tab so the user sees the pick land, Photos-app style.
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
                // Instant, unlike `slide(to:)`: `select` opens the expansion cover in this
                // same update, and a page still sliding in underneath it would hand the
                // cover's flight a moving source frame.
                selectedTab = .home
                viewModel.select(asset, detectedClips: recording.detectedClips)
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

/// The floating bottom nav: camera on the left, the gallery grid on the right. A custom
/// capsule rather than `TabView`'s own bar, which assumes more than two items.
private struct FloatingTabBar: View {
    let selectedTab: MainTab
    /// Pages to the tapped tab. The bar never writes the selection itself, so a tap can't
    /// skip the slide a swipe to the same page plays.
    let onSelect: (MainTab) -> Void
    /// Ties the selection pill to whichever icon is currently selected: only one of the
    /// two `tabButton`s ever draws it (see `indicator`), so a change in `selectedTab`
    /// reads to SwiftUI as that same shape flying from its old spot to its new one
    /// rather than one fading out while an unrelated one fades in.
    @Namespace private var glassNamespace

    var body: some View {
        let buttons = HStack(spacing: 40) {
            tabButton(.camera, systemImage: "camera.fill", label: "Camera")
            tabButton(.home, systemImage: "square.grid.2x2.fill", label: "Videos")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        // Drives the indicator's slide for every path to a selection change alike — a
        // tap, a swipe of the page `TabView`, or Camera's cancel chevron — overriding
        // whatever transaction the change arrived in, so the pill moves the same way for
        // all of them.
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

    private func tabButton(_ tab: MainTab, systemImage: String, label: String) -> some View {
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
        .accessibilityIdentifier("tab-\(label.lowercased())")
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
