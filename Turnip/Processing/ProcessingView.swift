import AVFoundation
import SwiftUI

/// Which way `ProcessingView`'s single swipe gesture is currently committed to acting: browse
/// (horizontal) or dismiss (vertical). Locked in per-drag by `dragAxis`.
private enum DragAxis {
    case horizontal
    case vertical
}

/// The pipeline progress screen (`docs/UIUX.md` § "Processing").
///
/// Pushed onto the flow's shared `NavigationStack` when a video is picked. It does *not*
/// start the pipeline on appear: the idle state fills the screen with the picked video
/// (no native playback chrome — a thin scrub bar draws over the bottom) and a manual
/// "Start analysis" button — black background, no title, Photos-app look. Once started
/// it shows real per-frame progress ("Analyzing frame 400 of 1,200"), and on success
/// navigates to `destination` with the detected clips — including a run that detected
/// zero tricks, which still navigates there rather than stopping on this screen; the
/// clip list itself puts up the "no tricks found" notice. Only the error state stays on
/// this screen, with a way back. Like the other pushed screens, it declares no
/// `NavigationStack` of its own.
///
/// The success destination is injected rather than hardcoded to the clip list, so
/// `Processing` never depends on `ClipList`'s view type (`ClipListView`): the screen
/// that pushes this one supplies `destination`. The destination also receives
/// `popToRoot` — the flow's "back to Home" action — so its back button can skip this
/// screen instead of stepping back through the flow.
struct ProcessingView<Destination: View>: View {
    let video: SelectedVideo
    let destination: (ProcessingResult, @escaping () -> Void) -> Destination
    /// `false` in previews, which would otherwise kick off a real pipeline run on appear.
    /// Home passes `false` too: analysis starts from the idle state's button, never
    /// automatically.
    let autostart: Bool
    /// Pops the flow's navigation stack back to Home. Threaded into the success
    /// destination so its back button returns to the start of the flow.
    let popToRoot: () -> Void
    /// This video's own poster frame, drawn under the player until it has decoded a frame of
    /// its own — so a screen that a swipe just slid into place shows the same picture the
    /// sliding page did, with no black between. Nil in previews and the screenshot harness,
    /// and for a video the library can't give a poster for; the player alone then fills in.
    let poster: PosterLoader?
    /// The videos before and after this one in Home's grid order, reached by swiping right and
    /// left respectively — nil at either end of the grid, where the swipe gives a little and
    /// springs back instead of wrapping around. Both are nil in previews and the screenshot
    /// harness, which have no grid to browse. Neither nilness disables the swipe while a run
    /// is in flight; the gesture itself does (`isAnalyzing`), since a swipe mid-run must not
    /// abandon it.
    let previous: BrowseNeighbor?
    let next: BrowseNeighbor?
    /// A browsed-to neighbor's resolution state — non-nil means the swipe has landed on a
    /// video that is still being fetched. Blocks the screen after a moment with the same
    /// determinate progress `ResolutionBanner` already renders on the grid (`Home`), so a slow
    /// iCloud fetch doesn't look like a swipe that went nowhere, while a local video resolves
    /// and replaces the screen before the overlay ever shows.
    let browsingNeighbor: VideoLibraryViewModel.Resolution?
    /// Cancels a browse in progress. Nil (never shown) in previews and the screenshot harness.
    let cancelBrowsing: (() -> Void)?
    /// Intercepts the back/cancel control's close instead of calling `dismiss()` directly, so
    /// a presenter can animate its own reverse transition before the cover actually goes away.
    /// `nil` (the default) falls back to `dismiss()`, unchanged for `ScreenshotHarness`/previews.
    var onRequestClose: (() -> Void)?
    /// Reports this screen's own vertical swipe-to-dismiss gesture to a presenter that wants to
    /// drive a Photos-style reverse flight live, rather than this screen committing it
    /// unilaterally — see `DismissGestureHooks`'s own doc comment.
    var dismissGestureHooks: DismissGestureHooks?

    /// Hands a presenter this screen's own vertical drag, live, instead of this screen deciding
    /// commit/cancel itself: `HomeExpansionContainer` drives its flying card's geometry straight
    /// off `onChanged`'s translation, the same way `ClipExpansionContainer`'s own dismiss drag
    /// does, and owns the "almost any downward release commits" rule — this screen's own
    /// `BrowseSwipe.commitDistance`/`flickDistance` threshold stays as the fallback for any
    /// caller that doesn't supply hooks (`ScreenshotHarness`, previews).
    struct DismissGestureHooks {
        /// Called on every update while the vertical axis is locked in, with the drag's raw
        /// `translation.height`.
        let onChanged: (CGFloat) -> Void
        /// Called once the drag ends on the vertical axis — the presenter owns the commit/
        /// cancel decision and the close flight from here.
        let onEnded: (_ translation: CGFloat, _ predictedTranslation: CGFloat) -> Void
        /// Called when the system cancels the drag before `onEnded` can run (an incoming call,
        /// Control Center) — the presenter's recovery signal, the same role
        /// `ClipExpansionContainer`'s `didHandleDragEnd`/`onChange` pairing plays: without it, a
        /// cancelled drag would leave the presenter's flight stuck mid-close forever.
        let onCancelled: () -> Void
    }

    @StateObject private var viewModel: ProcessingViewModel
    @State private var player: AVPlayer?
    /// The frame size as the player shows it (display orientation), loaded once in
    /// `.task` alongside the player — this view owns the player, so it owns the geometry
    /// the pose overlay needs to land on it too. Same computation as
    /// `ClipEditorViewModel.displayedSize`/`PoseDiagnosticViewModel.displaySize`.
    @State private var displaySize: CGSize?
    /// Seek coalescing for the progress-driven scrub: `ProgressReportClock` fires up to
    /// 10 times a second, and issuing an exact-tolerance seek per report would queue up
    /// keyframe-to-frame decodes on the same file the pipeline's own `AVAssetReader` is
    /// reading, slowing the very run the screen is showing. Only one seek is ever in
    /// flight; a report that lands mid-seek just replaces the pending target.
    @State private var pendingSeekTime: TimeInterval?
    @State private var isSeeking = false
    /// How far the page has been dragged from its resting position by a swipe-to-browse in
    /// progress, and where a committed one has parked it while the neighbor resolves. Reset
    /// by the drag's own end, or — when a committed browse is cancelled rather than landing —
    /// by `browsingNeighbor` clearing with this screen still up.
    @State private var dragTranslation: CGFloat = 0
    /// The neighbor a finished swipe committed to. Set from the moment the page starts its
    /// slide off screen until the browse lands (this screen is replaced) or falls through
    /// (the page springs back); further drags are ignored meanwhile, so an impatient second
    /// swipe can't drag the departed video back onto the screen.
    @State private var committedDirection: BrowseSwipe.Direction?
    /// Set by `VideoScrubBar` while a horizontal drag on its track is in progress. Guards
    /// `videoSwipeGesture` so a drag that starts on the scrub track only scrubs, never also
    /// carries the page along — see that gesture's own doc comment.
    @State private var isScrubbingVideo = false
    /// Latches `isScrubbingVideo` for the rest of the current drag, once `videoSwipeGesture`
    /// has seen it true at least once. `VideoScrubBar`'s own `onEnded` clears `isScrubbingVideo`
    /// the instant the finger lifts, which can reach this gesture's `onEnded` before it runs —
    /// reading the live flag there would let a scrub that just ended fall through to a browse
    /// commit on the same lift. This instead stays true for that whole gesture, and only resets
    /// once this gesture's own `onEnded` has run.
    @State private var dragWasScrub = false
    /// Which axis a drag committed to on its first recognized movement — set once per gesture
    /// and read instead of re-deriving from the live translation on every update, so a drag
    /// that changes direction mid-flight (right, then down) can't switch branches partway
    /// through and strand `dragTranslation` at whatever it last was.
    @State private var dragAxis: DragAxis?
    /// The window's size, measured by `swipeBackdrop`: how far a committed swipe carries the
    /// page so it leaves the screen entirely, where the neighbor pages sit while they wait
    /// offstage, and the size posters are requested at.
    @State private var pageSize: CGSize = .zero
    /// Starts as `initialPoster` — a poster already in hand is on screen from the first
    /// frame, since `loadPosters()` can only deliver one a frame or more later.
    @State private var posterImage: UIImage?
    @State private var neighborPosters: [BrowseSwipe.Direction: UIImage] = [:]
    /// Whether `browsingOverlay` is up. Lags `browsingNeighbor` by `browsingOverlayDelay`, so a
    /// local video's near-instant resolve never flashes it over the page that just slid in.
    @State private var showsBrowsingProgress = false
    /// True from the moment a vertical drag locks in until `dismissGestureHooks?.onEnded` (or
    /// the cancellation path below) has handled it — not reset by `dragAxis`'s own `onEnded`
    /// `defer`, which can already have cleared `dragAxis` to `nil` by the time the cancellation
    /// check below runs.
    @State private var isTrackingDismissDrag = false
    /// Resets to `true` on every touch-down, `false` on every touch-up or cancellation —
    /// `@GestureState` rather than a plain flag so a system-cancelled drag (an incoming call,
    /// Control Center) still resets it even though `onEnded` never fires for one.
    @GestureState private var isDragTouchActive = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    /// How long a committed swipe takes to carry the page the rest of the way off screen.
    /// Computed, since a generic type can't hold a stored static.
    private static var slideDuration: TimeInterval { 0.25 }
    private static var browsingOverlayDelay: TimeInterval { 0.4 }

    init(
        video: SelectedVideo,
        runner: any ProcessingRunning = ProcessingPipeline(),
        autostart: Bool = true,
        popToRoot: @escaping () -> Void = {},
        initialPoster: UIImage? = nil,
        poster: PosterLoader? = nil,
        previous: BrowseNeighbor? = nil,
        next: BrowseNeighbor? = nil,
        browsingNeighbor: VideoLibraryViewModel.Resolution? = nil,
        cancelBrowsing: (() -> Void)? = nil,
        onRequestClose: (() -> Void)? = nil,
        dismissGestureHooks: DismissGestureHooks? = nil,
        destination: @escaping (ProcessingResult, @escaping () -> Void) -> Destination
    ) {
        self.video = video
        self.autostart = autostart
        self.popToRoot = popToRoot
        self.poster = poster
        _posterImage = State(initialValue: initialPoster)
        self.previous = previous
        self.next = next
        self.browsingNeighbor = browsingNeighbor
        self.cancelBrowsing = cancelBrowsing
        self.onRequestClose = onRequestClose
        self.dismissGestureHooks = dismissGestureHooks
        self.destination = destination
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(runner: runner))
    }

    private func close() {
        if let onRequestClose {
            onRequestClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        // The back/cancel control is a sibling of the draggable strip, not a passenger inside
        // it: it stays floating in place through every swipe — horizontal browse or vertical
        // dismiss — rather than sliding with whichever page is currently under the finger.
        ZStack(alignment: .topLeading) {
            // A three-page strip with this video's page in the middle: the neighbors wait one
            // window-width to either side and move with the same drag, so the one being swiped
            // toward enters as this one leaves, the way the Camera page arrives over Home.
            ZStack {
                if previous != nil {
                    neighborPage(.previous)
                }
                if next != nil {
                    neighborPage(.next)
                }
                page
                    .offset(x: dragTranslation)
            }
            // The strip is draggable edge to edge, whatever each branch happens to draw —
            // `videoStage`'s player is a `UIViewRepresentable`, and the status states leave
            // transparent space around their text. The backdrop behind covers the rest of the
            // window, which is what a `contentShape` bounded by this view's own frame cannot.
            .contentShape(Rectangle())
            .background(swipeBackdrop)
            // One attachment, covering every page of the strip plus the safe-area-inset content
            // `videoStage` adds below its own video area, and — through the backdrop — the strips
            // outside the safe area as well. `.simultaneousGesture`, not `.highPriorityGesture`:
            // nesting two `.highPriorityGesture`s (this one and `VideoScrubBar`'s track) does not
            // reliably let the descendant win on device, so this one runs alongside the track's
            // instead and defers to it explicitly via `isScrubbingVideo`. See the gesture's own
            // doc comment.
            .simultaneousGesture(videoSwipeGesture)
            topLeadingControl
            // Last in the stack, so it draws over both the strip and the top-leading control —
            // it belongs to the video arriving, not to anything on the page leaving, and it
            // must block the control too or a tap during a browse-in-flight would dismiss out
            // from under the resolve it's waiting on.
            if showsBrowsingProgress, let browsingNeighbor {
                browsingOverlay(browsingNeighbor)
            }
        }
        // No navigation bar at all, rather than a transparent one: the bar is the navigation
        // stack's own view, laid over this screen's content, so a drag that starts in its
        // band never reaches this screen's gesture. The back button stays hidden as well:
        // SwiftUI's interactive edge-swipe-to-pop rides on it, and a swipe that starts at the
        // leading edge has to browse to the previous video like any other.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(isPresented: $viewModel.isShowingClips) {
            if let result = viewModel.result {
                destination(result, popToRoot)
            }
        }
        .task {
            if player == nil {
                let newPlayer = AVPlayer(playerItem: AVPlayerItem(sdrAsset: video.asset))
                player = newPlayer
                // Autoplay on arrival: opening this screen from a video tile is the
                // user's play action, Photos-app style — no separate tap needed.
                newPlayer.play()
            }
            if displaySize == nil,
               let track = try? await video.asset.loadTracks(withMediaType: .video).first,
               let naturalSize = try? await track.load(.naturalSize),
               let preferredTransform = try? await track.load(.preferredTransform) {
                displaySize = ClipEditorViewModel.displayedSize(
                    naturalSize: naturalSize, preferredTransform: preferredTransform)
            }
            if autostart {
                viewModel.start(video: video)
            }
        }
        // Posters are sized to the window, so they wait for `swipeBackdrop`'s first measurement.
        .task(id: pageSize) {
            await loadPosters()
        }
        .task(id: browsingNeighbor != nil) {
            guard browsingNeighbor != nil else {
                showsBrowsingProgress = false
                return
            }
            try? await Task.sleep(for: .seconds(Self.browsingOverlayDelay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) { showsBrowsingProgress = true }
        }
        .onChange(of: currentProgress?.timestamp) { newValue in
            guard let newValue, let player else { return }
            requestSeek(to: newValue, on: player)
        }
        .onChange(of: browsingNeighbor == nil) { settled in
            // A browse that lands replaces this screen outright, so the only way back here
            // with the page still parked off screen is a cancelled or failed one.
            guard settled, committedDirection != nil else { return }
            springBack()
        }
        .onChange(of: isDragTouchActive) { isActive in
            // The system cancelled a vertical drag (incoming call, Control Center) before
            // `onEnded` could run `dismissGestureHooks.onEnded` — without this, a presenter
            // driving a live close flight off this screen's reports would stay stuck mid-close
            // forever, the same failure mode `ClipExpansionContainer` hit before its own fix.
            guard !isActive, isTrackingDismissDrag, let hooks = dismissGestureHooks else { return }
            isTrackingDismissDrag = false
            hooks.onCancelled()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    /// This video's page: the state-dependent content. The screen's top-leading control is a
    /// sibling of the whole draggable strip in `body`, not of this, so it stays fixed while
    /// this slides.
    @ViewBuilder
    private var page: some View {
        switch viewModel.state {
        case .idle, .processing:
            videoStage
        case .failed(let message):
            // `StatusStateView` sizes to its own content otherwise, the same as every
            // other consumer of this view (`HomeView`'s empty grid and denied states apply
            // the same frame externally). Neither of these two branches carries a
            // `.safeAreaInset` the way `videoStage` does, so extending each into the safe
            // area can't move what that inset is measured from.
            errorState(message: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        case .succeeded:
            // Covered by the pushed destination; only visible when navigating back here.
            Text("Analysis complete.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
    }

    /// Back to Home, or — while a run is in flight — cancel it, which also leaves. The same
    /// scrim-circle button the Camera page floats over its preview, since with no navigation
    /// bar this screen's chrome sits over its media the same way. A sibling of the draggable
    /// strip in `body`, so neither a horizontal browse-swipe nor a vertical dismiss-swipe
    /// carries it along.
    @ViewBuilder
    private var topLeadingControl: some View {
        if isAnalyzing {
            ScrimIconButton(systemImage: "xmark", accessibilityLabel: "Cancel") {
                handleBackAction()
            }
            .padding()
        } else {
            ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to Home") {
                handleBackAction()
            }
            .padding()
        }
    }

    /// What the top-leading control does, and what letting go of a committed swipe-down does
    /// too: cancel a run in flight, then leave either way.
    private func handleBackAction() {
        if isAnalyzing {
            viewModel.cancel()
        }
        close()
    }

    /// The in-flight run's latest progress report, or `nil` outside `.processing` — the
    /// scrub/overlay's single read of `viewModel.state`'s associated value.
    private var currentProgress: ProcessingProgress? {
        if case .processing(let progress) = viewModel.state { return progress }
        return nil
    }

    /// Queues a scrub to `time`, coalescing with any seek already in flight (see the
    /// `pendingSeekTime` doc comment). Also pauses the player: once analysis is driving
    /// the picture, free-running playback would fight the scrub on every report.
    private func requestSeek(to time: TimeInterval, on player: AVPlayer) {
        player.pause()
        pendingSeekTime = time
        guard !isSeeking else { return }
        isSeeking = true
        performNextSeek(on: player)
    }

    private func performNextSeek(on player: AVPlayer) {
        guard let time = pendingSeekTime else {
            isSeeking = false
            return
        }
        pendingSeekTime = nil
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance, toleranceAfter: tolerance
        ) { _ in
            Task { @MainActor in performNextSeek(on: player) }
        }
    }

    /// Back/Cancel track the *processing* state rather than `viewModel.isRunning`: idle is
    /// this screen's resting state now (analysis starts manually), so it keeps the back
    /// chevron to Home. `isRunning` still counts idle as running — the pipeline's tests
    /// lean on that — so it can't drive this.
    private var isAnalyzing: Bool {
        if case .processing = viewModel.state { return true }
        return false
    }

    /// Whether a swipe can act right now: not while a run is in flight (a swipe — browse or
    /// dismiss alike — must not abandon it; the top-leading control stays live as a Cancel
    /// button through `.processing` for that), and not from the moment one swipe commits until
    /// its browse lands or falls through.
    private var canBrowse: Bool {
        !isAnalyzing && browsingNeighbor == nil && committedDirection == nil
    }

    // MARK: - Swipe to browse / swipe to dismiss

    /// A right drag uncovers the previous video, a left drag the next, and a down drag leaves
    /// the screen the same way the top-leading control does: the whole strip follows a
    /// horizontal finger, springs back if it falls short, and at either end of the grid gives
    /// only a little, since there is no neighbor to uncover — `BrowseSwipe` owns that
    /// arithmetic, including the flick that commits a short drag, and it's reused for the
    /// down-swipe's own commit-distance/flick check.
    ///
    /// `body` attaches this once, as high in the tree as the screen's content goes, rather than
    /// separately on every sub-region — as a `.simultaneousGesture`, so it runs alongside
    /// `VideoScrubBar`'s own track gesture instead of competing with it for the same touch.
    /// Two guards keep this gesture from acting on a touch the track already owns:
    /// `dragWasScrub` latches for the whole drag once `isScrubbingVideo` (`VideoScrubBar`'s
    /// `onScrubbingChanged` callback, which reaches this ahead of this gesture's own 20pt
    /// `minimumDistance` since the track's is 0pt) has read true even once, so this gesture's
    /// own `onEnded` can't act on a lift whose `isScrubbingVideo` already flipped back to
    /// false. What neither this nor gesture priority needs to handle is the page `TabView` this
    /// screen sits inside (`RootTabView`): its pager is a UIKit scroll view that takes a
    /// horizontal drag before SwiftUI's gesture system sees it, so `PageSwipeLock` switches the
    /// pager off while any screen is pushed over Home.
    ///
    /// `dragAxis` locks in which of the two this drag is, from its first recognized movement,
    /// rather than re-deriving it from the live translation on every update — a drag that
    /// changes direction partway through (right, then down) stays whichever it started as.
    private var videoSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($isDragTouchActive) { _, state, _ in state = true }
            .onChanged { value in
                if isScrubbingVideo { dragWasScrub = true }
                guard !dragWasScrub else { return }
                if dragAxis == nil {
                    dragAxis = isDownwardTranslation(value.translation) ? .vertical : .horizontal
                    if dragAxis == .vertical { isTrackingDismissDrag = true }
                }
                if dragAxis == .vertical {
                    guard canBrowse, let hooks = dismissGestureHooks else { return }
                    hooks.onChanged(value.translation.height)
                    return
                }
                guard canBrowse else { return }
                dragTranslation = BrowseSwipe.pageOffset(
                    translation: value.translation.width,
                    hasPrevious: previous != nil, hasNext: next != nil)
            }
            .onEnded { value in
                defer {
                    dragWasScrub = false
                    dragAxis = nil
                }
                guard !dragWasScrub else { return }
                if dragAxis == .vertical {
                    defer { isTrackingDismissDrag = false }
                    guard canBrowse else { return }
                    if let hooks = dismissGestureHooks {
                        hooks.onEnded(value.translation.height, value.predictedEndTranslation.height)
                        return
                    }
                    let translation = value.translation.height
                    let predicted = value.predictedEndTranslation.height
                    if translation >= BrowseSwipe.commitDistance || predicted >= BrowseSwipe.flickDistance {
                        handleBackAction()
                    }
                    return
                }
                // A drag that was never allowed to move the strip has nothing to undo; one
                // that started while browsing was allowed and ended after it stopped being
                // (the run started, say) springs back like a drag that fell short.
                guard canBrowse else { return }
                guard let direction = BrowseSwipe.commit(
                    translation: value.translation.width,
                    predictedTranslation: value.predictedEndTranslation.width,
                    hasPrevious: previous != nil, hasNext: next != nil)
                else {
                    springBack()
                    return
                }
                commit(direction)
            }
    }

    /// Whether `translation` reads as the start of a downward swipe rather than a horizontal
    /// browse: more vertical travel than horizontal, and moving down rather than up (an upward
    /// drag isn't a gesture this screen gives meaning to, so it's treated as the horizontal
    /// branch, which a translation with so little width leaves inert).
    private func isDownwardTranslation(_ translation: CGSize) -> Bool {
        translation.height > 0 && abs(translation.height) > abs(translation.width)
    }

    /// Carries the strip the rest of the way, so the neighbor's page sits where this one was,
    /// then browses. The browse waits for the slide to finish: a local video resolves faster
    /// than the page moves, and landing mid-slide would cut the motion short. Stops the idle
    /// player first — nothing would call `pause()` on it once this screen's identity changes
    /// underneath it, the same reason `idleControls`' "Start analysis" button pauses first.
    private func commit(_ direction: BrowseSwipe.Direction) {
        committedDirection = direction
        player?.pause()
        withAnimation(.easeOut(duration: Self.slideDuration)) {
            dragTranslation = direction == .previous ? pageSize.width : -pageSize.width
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.slideDuration))
            guard committedDirection == direction else { return }
            let neighbor = direction == .previous ? previous : next
            if neighbor?.browse() != true {
                springBack()
            }
        }
    }

    private func springBack() {
        committedDirection = nil
        withAnimation(.easeOut(duration: 0.2)) { dragTranslation = 0 }
    }

    /// The full-window surface the swipe is measured and hit-tested against. A `.background`
    /// rather than an `.ignoresSafeArea()` on the screen's own content: that would also move
    /// what `videoStage`'s `.safeAreaInset` insets from, dropping the scrub bar and the
    /// "Start analysis" button under the home indicator. Black, so it reads as the same
    /// backdrop `videoStage` already draws.
    private var swipeBackdrop: some View {
        GeometryReader { proxy in
            Color.black
                .onAppear { pageSize = proxy.size }
                .onChange(of: proxy.size) { pageSize = $0 }
        }
        .ignoresSafeArea()
    }

    /// The page for the video one swipe away in `direction`, laid out like `page` in its idle
    /// state: the poster aspect-fit into the full window exactly as `BareVideoPlayerView` fits
    /// the video itself, under the same resting controls the arriving screen will draw — so
    /// what slides in is the screen about to land, and landing changes nothing but the poster
    /// giving way to the player. No chevron of its own: `topLeadingControl` is a fixed sibling
    /// of the whole strip in `body`, already on screen throughout the swipe, so a second one
    /// here would double up rather than hand off. Inert: nothing here can be tapped, and
    /// nothing here is an accessibility element — the stand-in controls are replaced wholesale
    /// by an empty representation rather than merely hidden, since the real controls arrive
    /// with the real screen and a second "Start analysis" a screen-width offstage would still
    /// be found by anything walking the element tree.
    private func neighborPage(_ direction: BrowseSwipe.Direction) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = neighborPosters[direction] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                VideoScrubBar.Placeholder()
                    .padding(.horizontal)
                PrimaryActionBar("Start analysis") {}
            }
        }
        .allowsHitTesting(false)
        .accessibilityRepresentation { EmptyView() }
        .offset(x: dragTranslation + (direction == .previous ? -pageSize.width : pageSize.width))
    }

    /// Requests this video's poster and both neighbors' at the window's pixel size, once the
    /// window has been measured. Each loads independently; a neighbor whose poster hasn't
    /// arrived by the time a swipe starts simply slides in black until it does.
    private func loadPosters() async {
        guard pageSize != .zero else { return }
        let pixelSize = ThumbnailLoader.pixelSize(for: pageSize, scale: displayScale)
        async let own = poster?(pixelSize)
        async let previousPoster = previous?.poster(pixelSize)
        async let nextPoster = next?.poster(pixelSize)
        if posterImage == nil, let image = await own {
            posterImage = image
        }
        if let image = await previousPoster {
            neighborPosters[.previous] = image
        }
        if let image = await nextPoster {
            neighborPosters[.next] = image
        }
    }

    /// Mirrors `ResolutionBanner`'s two-state rendering of the same `Resolution` type — an
    /// iCloud download shows its real progress, a local/composition resolve shows an
    /// indeterminate spinner — so a swipe-triggered browse reports the same way the grid's
    /// own tile-tap resolution already does.
    private func browsingOverlay(_ resolution: VideoLibraryViewModel.Resolution) -> some View {
        VStack(spacing: 12) {
            if let progress = resolution.downloadProgress {
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
            if let cancelBrowsing {
                Button("Cancel", role: .cancel, action: cancelBrowsing)
                    .tint(.white)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .transition(.opacity)
    }

    // MARK: - Video stage

    /// The video stage: the picked video fills the screen with no native playback
    /// chrome (`BareVideoPlayerView`) — Photos-app look, black background, no title, no
    /// caption. This backs both `.idle` (scrub bar + "Start analysis" button over the
    /// bottom) and `.processing` (progress overlay over the bottom instead) — the video
    /// stays on screen and paused behind the progress UI rather than the analysis
    /// replacing it with a separate page.
    private var videoStage: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Under the player, which is transparent until it has decoded a frame: the same
            // letterbox fit, so the first decoded frame lands exactly over it.
            if let posterImage {
                Image(uiImage: posterImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            if let player {
                BareVideoPlayerView(player: player)
                    .ignoresSafeArea()
                    // Hands the player itself outward too, so the expansion transition's
                    // card can draw the same frames this stage draws and scrub them on close.
                    .preference(key: ProcessingPlayerPreferenceKey.self, value: ProcessingPlayerHandle(player: player))
            } else {
                ProgressView().tint(.white)
            }
            if let displaySize {
                // Reports the video's actual letterboxed rect (global space), not this
                // stage's own full-screen bounds, so a Photos-style expansion transition
                // flying in from Home can land its card exactly where the video's pixels
                // really are instead of the surrounding black bars — the same reasoning
                // `poseOverlay` below already uses this math for, just reported outward
                // instead of drawn on top.
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ProcessingVideoFramePreferenceKey.self,
                        value: AVMakeRect(aspectRatio: displaySize, insideRect: proxy.frame(in: .global)))
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            if isAnalyzing {
                Color.black.opacity(0.45).ignoresSafeArea()
                if let progress = currentProgress, let displaySize {
                    poseOverlay(keypoints: progress.keypoints, displaySize: displaySize)
                }
            }
        }
        // `body`'s single `.simultaneousGesture(videoSwipeGesture)` attachment (see its own doc
        // comment) covers this whole stage, video area and safe-area inset alike — nothing is
        // attached here directly.
        // `.safeAreaInset`, not `.overlay`: an overlay sizes its content at its own
        // ideal width and aligns it, so `PrimaryActionBar`'s full-width button has no
        // wider proposal to expand into and stays text-hugging. A safe-area inset
        // reserves real full-width space instead.
        .safeAreaInset(edge: .bottom) {
            if case .processing(let progress) = viewModel.state {
                processingOverlay(progress)
            } else {
                idleControls
            }
        }
    }

    /// The current frame's skeleton, positioned over the exact letterboxed rect
    /// `BareVideoPlayerView`'s `.resizeAspect` gravity draws the video into — not a
    /// full-bleed canvas, which would misalign against the video's own aspect-fit letterbox
    /// whenever the source isn't exactly screen-shaped. `AVMakeRect` computes that same
    /// letterbox math; `.ignoresSafeArea()` matches the `GeometryReader` proxy's frame to
    /// the player's, since the player itself ignores the safe area.
    private func poseOverlay(keypoints: [PoseKeypoint], displaySize: CGSize) -> some View {
        GeometryReader { proxy in
            let frame = AVMakeRect(aspectRatio: displaySize, insideRect: proxy.frame(in: .local))
            PoseOverlayView(keypoints: keypoints)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var idleControls: some View {
        VStack(spacing: 12) {
            if let player {
                // `onScrubbingChanged` feeds `isScrubbingVideo`, which `videoSwipeGesture`
                // checks so a drag on the track never also carries the page — see that
                // gesture's own doc comment.
                VideoScrubBar(player: player, onScrubbingChanged: { isScrubbingVideo = $0 })
                    .padding(.horizontal)
            }
            // Pause the idle player before this state leaves the hierarchy:
            // nothing would call `pause()` on it afterwards, so its audio would
            // keep playing behind the progress UI and the clip list.
            PrimaryActionBar("Start analysis") {
                player?.pause()
                viewModel.start(video: video)
            }
        }
    }

    /// The progress panel drawn over the bottom of the still-visible, paused video —
    /// replaces `idleControls` in the same safe-area inset rather than replacing the
    /// video stage itself.
    private func processingOverlay(_ progress: ProcessingProgress) -> some View {
        VStack(spacing: 12) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(.white)
                    .accessibilityLabel("Analysis progress")
            } else {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("Analyzing video")
            }
            Text(progress.label)
                .font(.headline)
                .foregroundStyle(.white)
            Text("This runs fully on-device and can take a while for long videos.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
    }

    private func errorState(message: String) -> some View {
        StatusStateView(
            systemImage: "exclamationmark.triangle",
            title: "Couldn't analyze this video",
            message: message
        ) {
            VStack(spacing: 12) {
                Button("Retry") { viewModel.retry(video: video) }
                    .buttonStyle(.borderedProminent)
                Button("Back to Home", role: .cancel) { close() }
            }
            .padding(.top, 8)
        }
    }
}

/// `videoStage`'s own letterboxed video rect (global space) — see that property's inline
/// comment for why it's reported rather than drawn. Reduces to the latest non-zero value
/// (matching `ClipEditorPreviewFramePreferenceKey`'s own `reduce`): `displaySize` is nil for
/// the first render or two while the asset's track info loads, during which this view simply
/// isn't in the tree yet, so the default `.zero` should never overwrite a real measurement.
/// `videoStage`'s player, reported outward alongside its frame so a Photos-style expansion
/// transition can render the same player in its flying card — see `HomeExpansionContainer`.
/// Reduces to the latest non-nil value for the same reason `ProcessingVideoFramePreferenceKey`
/// does: a state whose stage isn't in the tree reports nothing, and that shouldn't overwrite
/// a real player.
struct ProcessingPlayerPreferenceKey: PreferenceKey {
    static var defaultValue = ProcessingPlayerHandle(player: nil)
    static func reduce(value: inout ProcessingPlayerHandle, nextValue: () -> ProcessingPlayerHandle) {
        let next = nextValue()
        if next.player != nil { value = next }
    }
}

/// `ProcessingPlayerPreferenceKey`'s value: a player compared by identity, since
/// `onPreferenceChange` needs `Equatable` and `AVPlayer` isn't.
struct ProcessingPlayerHandle: Equatable {
    let player: AVPlayer?

    static func == (lhs: ProcessingPlayerHandle, rhs: ProcessingPlayerHandle) -> Bool {
        lhs.player === rhs.player
    }
}

struct ProcessingVideoFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

#Preview {
    NavigationStack {
        ProcessingView(
            video: SelectedVideo(
                assetIdentifier: "preview",
                asset: AVURLAsset(url: URL(fileURLWithPath: "/nonexistent.mov")),
                duration: 12
            ),
            autostart: false,
            destination: { result, _ in
                Text("\(result.clips.count) clips")
            }
        )
    }
    .preferredColorScheme(.dark)
}
