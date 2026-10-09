import SwiftUI

/// The tapped tile's Photos-style open/close flight into Turnip's crop-hole editor.
///
/// Two layers share one `progress` clock (`0` = exactly at the tile, `1` = fully open).
/// A "card" carries the geometry the whole way: the editor's own video surface
/// (`ClipEditorVideoSurface`, rendering the very same `AVPlayer` the editor renders),
/// laid out at the editor's fixed crop marker exactly as the editor's stage lays it out
/// — the video placed so its crop rect fills the marker — and shown through a window that
/// uncrops from the part the tile showed — the marker's center square — to the marker,
/// scaled uniformly so the picture is cropped as it grows, never stretched
/// (`ExpansionFlightGeometry`). The real `ClipEditorView`'s video surface and frosted
/// surround are hidden for the entire flight and cut in once the card has arrived
/// (`expansionHasLanded`); inside the marker both layers draw the same player at the
/// same frame in the same place, so the cut there is invisible, and the rest of the
/// frame appears around it under the frosted glass with the landing.
///
/// The player is scrubbed alongside the geometry. Opening, it starts on the frame the
/// tile was showing when tapped (`sourceTime`) and plays back to the clip's first frame
/// as the card grows, so the editor's loop then starts where the card left off. Closing,
/// it starts on whatever frame the editor is showing and scrubs to the frame the tile
/// will show again when it's revealed, so the video shrinks into the tile with no cut.
///
/// `progress` is animated for the tap-to-open and back-button-close paths, and driven
/// 1:1 by drag translation for the interactive swipe-to-dismiss — the same geometry
/// math serves both. The swipe-to-dismiss gesture is handed to `ClipEditorView` to
/// attach on its own root view's background rather than living out here behind it:
/// `NavigationStack` is backed by a real `UIViewController`, and a touch landing on
/// *its* empty space resolves to that hosting view, not through to a SwiftUI sibling
/// behind it in this `ZStack` — a gesture out here would never fire at all.
struct ClipExpansionContainer: View {
    /// The tapped tile's on-screen frame at the moment of the tap, in global
    /// coordinate space — the flight's start (opening) and end (closing) point.
    let sourceFrame: CGRect
    /// The frame the tile was showing when tapped, in asset time: its paused loop's
    /// position, or its poster's time when it has no loop. The opening flight starts on
    /// this frame, and a closing flight lands back on it, because the tile is still
    /// showing it when it's revealed.
    let sourceTime: TimeInterval
    /// The tile's already-decoded poster frame, drawn under the card's video surface at
    /// the crop rect so the card has a picture from the first frame of a flight even
    /// when the player hasn't decoded one yet.
    let thumbnail: CGImage?
    let source: ClipEditorSource
    let onCommit: (ClipEditorResult) -> Void
    let onDelete: () -> Void
    /// Called the instant the opening flight starts moving — which is when the presenter
    /// should hide the tile underneath. Not at presentation: the card waits for its video
    /// surface to be able to show `sourceTime`'s frame first, and until then the tile
    /// itself is what's on screen.
    let onFlightStarted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ClipEditorViewModel
    @StateObject private var scrubber: FlightScrubber
    @State private var progress: CGFloat = 0
    /// The editor's crop marker frame, as `ClipEditorCropMarkerFramePreferenceKey` reports
    /// it — the flight's destination. Live through the opening flight — a newly mounted view's
    /// first reports settle over a few passes — and frozen from the moment a close can
    /// begin, see `acceptsDestinationUpdates`.
    @State private var measuredMarker: CGRect?
    /// Gates `measuredMarker` updates: `true` through the opening flight, `false`
    /// from the first touch-move of an interactive drag, or from the moment
    /// `close()`/`closeForDelete()` runs, whichever comes first — for the rest of this
    /// container's life. Once the user could be leaving, the flight's endpoint shouldn't
    /// keep tracking a value that could still move underneath it.
    @State private var acceptsDestinationUpdates = true
    /// The live drag, via `@GestureState` rather than a plain `@State` flag: a system
    /// cancellation (an incoming call, Control Center, the home-indicator swipe-up
    /// zone this dismiss drag sits just above) resets `@GestureState` back to `nil`
    /// even though `DragGesture.onEnded` never fires. A plain flag would stay stuck
    /// `true` — `progress` would stay below 1, and `.allowsHitTesting(editorOpacity >
    /// 0.99)` below would leave every control, including the back button, permanently
    /// disabled with no way out. The `onChange` below is the reset's own signal.
    @GestureState private var dragTranslation: CGSize?
    /// Set by `onEnded` so the `onChange` below can tell a normal end (already
    /// resolved to a commit or a cancel-spring) from a system cancellation (which
    /// still needs the cancel-spring applied, since `onEnded` never ran it).
    @State private var didHandleDragEnd = false
    /// The frame the editor was showing when an interactive drag began scrubbing, so a
    /// cancelled drag can scrub back to it. `nil` while no drag is in progress.
    @State private var dragScrubOrigin: TimeInterval?
    /// Delete fades the whole view out in place instead of flying to `sourceFrame`:
    /// by the time this runs, that tile's slot in the grid holds a different item (or
    /// nothing), so flying there would land in the wrong spot.
    @State private var deleteFadeOpacity: CGFloat = 1
    /// The two readiness signals the opening flight waits for, and whether it has
    /// started. The card's video surface is transparent until the player has decoded a
    /// frame, and that frame is only the right one once the seek to `sourceTime` has
    /// completed; starting the flight before both would grow either an empty window or
    /// the wrong frame over the hidden tile.
    @State private var isSeekedToSource = false
    @State private var isSurfaceReady = false
    @State private var hasStartedOpenFlight = false
    /// Set by `close()`/`closeForDelete()`, so a deferred step from an earlier flight
    /// (releasing playback after an open, resuming it after a cancelled drag) that lands
    /// after the user has already started leaving does nothing instead of restarting the
    /// loop under the closing scrub.
    @State private var isClosing = false
    /// Whether the card has landed on the editor's preview: `true` from the opening
    /// flight's completion until the first frame of any close. Drives the hard cut
    /// between the card and the editor's video surface — both read it, and it's written
    /// with animations disabled (`setLanded`), so the swap is one atomic, unanimated
    /// frame. Also handed to the editor as `expansionHasLanded`; see that environment
    /// value for why it's a flag rather than the live `progress`.
    @State private var hasLanded = false

    private let flightDuration = ExpansionFlightGeometry.flightDuration
    /// How long the opening flight waits for the card's video surface before starting
    /// anyway, with the poster thumbnail standing in for a frame that never came.
    private let surfaceReadinessTimeout: TimeInterval = 0.3
    /// Downward drag distance, in points, that fully closes the view.
    private let dismissTravel: CGFloat = 420
    /// The tile's own corner radius (`ClipCardView.tile`'s `clipShape`) — the flying
    /// card's radius eases to 0 as it grows, matching the editor's sharp-cornered
    /// preview.
    private let sourceCornerRadius: CGFloat = 8

    init(
        sourceFrame: CGRect,
        sourceTime: TimeInterval,
        thumbnail: CGImage?,
        source: ClipEditorSource,
        onCommit: @escaping (ClipEditorResult) -> Void,
        onDelete: @escaping () -> Void,
        onFlightStarted: @escaping () -> Void
    ) {
        self.sourceFrame = sourceFrame
        self.sourceTime = sourceTime
        self.thumbnail = thumbnail
        self.source = source
        self.onCommit = onCommit
        self.onDelete = onDelete
        self.onFlightStarted = onFlightStarted
        let viewModel = ClipEditorViewModel(source: source)
        _viewModel = StateObject(wrappedValue: viewModel)
        _scrubber = StateObject(wrappedValue: FlightScrubber { time in await viewModel.scrub(to: time) })
    }

    var body: some View {
        GeometryReader { screen in
            let screenRect = CGRect(origin: .zero, size: screen.size)
            // The card is the editor's crop marker: the video placed in it exactly as the
            // editor places it under the marker, so inside the marker the settled card and
            // the editor's own surface are the same picture. The flight shows the crop and
            // nothing outside it; the rest of the frame, under the editor's frosted
            // surround, only appears once the card has landed and the editor's own
            // edge-to-edge surface takes over.
            let destination = measuredMarker ?? fallbackMarker(in: screenRect)
            // The card's whole content, in its own coordinates: what the tile shows, and so
            // the part of the card the window starts on.
            let focus = CGRect(origin: .zero, size: destination.size)
            let chromeCrossfades = ExpansionFlightGeometry.destinationChromeCrossfades

            ZStack {
                Color(.systemBackground)
                    .expansionCrossfade(
                        progress: progress,
                        inflection: ExpansionFlightGeometry.scrimCrossfadeInflection,
                        steepness: ExpansionFlightGeometry.scrimCrossfadeSteepness)
                    .ignoresSafeArea()

                if !chromeCrossfades {
                    // Under the card, hidden for the whole flight and cut in once the card
                    // has landed: the pre-iOS 18 fallback, where the editor's navigation
                    // container can't be made see-through (see `destinationChromeCrossfades`).
                    editor(size: screen.size)
                        .opacity(hasLanded ? 1 : 0)
                }

                cardLayer(destination: destination, focus: focus)
                    // Rendered as one group before any opacity touches it: with Delete's
                    // fade applied straight to the live player view, the video spilled past
                    // the window's clip below and showed the frame outside the marker sharp
                    // for the whole fade.
                    .compositingGroup()
                    // The hard cut to the editor's video surface — unanimated, since
                    // `hasLanded` is only ever written with animations disabled.
                    .opacity(hasLanded ? 0 : 1)
                    // The layer these wrap (post-`.position`) has its origin at the
                    // screen's, which both rely on.
                    .clipShape(ExpansionFlightClip(
                        progress: progress, sourceFrame: sourceFrame, destination: destination,
                        focus: focus, sourceCornerRadius: sourceCornerRadius))
                    .modifier(ExpansionFlightEffect(
                        progress: progress, sourceFrame: sourceFrame, destination: destination, focus: focus))
                    .allowsHitTesting(!hasLanded)

                if chromeCrossfades {
                    // Over the card, fading in with the flight: the editor's chrome (its
                    // top row, the playback pill, the trim slider) cross-fades in place over
                    // the growing picture, while its own video surface, frosted surround and
                    // marker outline stay hidden under `expansionHasLanded` until the card
                    // has landed. A plain `.opacity`, not a cut: it's meant to
                    // interpolate across the whole flight, which `.opacity` does on its own.
                    editor(size: screen.size)
                        .expansionCrossfade(
                            progress: progress,
                            inflection: ExpansionFlightGeometry.chromeCrossfadeInflection,
                            steepness: ExpansionFlightGeometry.chromeCrossfadeSteepness)
                }
            }
            .opacity(deleteFadeOpacity)
        }
        .ignoresSafeArea()
        .onAppear(perform: armOpenFlight)
        .onChange(of: dragTranslation != nil) { isDraggingNow in
            guard !isDraggingNow else { return }
            guard !didHandleDragEnd else {
                didHandleDragEnd = false
                return
            }
            // `onEnded` never ran (system-cancelled) — fall back to the same
            // cancel-flight a normal non-committing release would use.
            cancelDrag()
        }
    }

    /// The real editor in its own navigation stack, with `hasLanded` handed down for its
    /// video-surface cut and its crop marker frame handed back up. Built by one of the two
    /// branches in `body`. The stack's own background is made see-through so the editor can
    /// fade in over the card; this container's scrim is its backdrop instead.
    private func editor(size: CGSize) -> some View {
        NavigationStack {
            ClipEditorView(
                viewModel: viewModel,
                onCommit: onCommit,
                onDelete: onDelete,
                onRequestClose: close,
                onRequestDeleteClose: closeForDelete,
                dismissGesture: dismissDragGesture)
            .expansionTransparentNavigationContainer()
        }
        .frame(width: size.width, height: size.height)
        .environment(\.expansionHasLanded, hasLanded)
        .allowsHitTesting(hasLanded)
        .onPreferenceChange(ClipEditorCropMarkerFramePreferenceKey.self) { frame in
            guard acceptsDestinationUpdates, frame != .zero else { return }
            measuredMarker = frame
        }
    }

    /// Laid out at `destination` (the marker) — fixed, not animated — with
    /// `ExpansionFlightClip`/`ExpansionFlightEffect` doing the actual flight on top. The
    /// video surface inside lays the whole frame out around `focus`, past the card's own
    /// bounds; the flight's window never reaches past them, so only the crop ever shows.
    /// The video surface is invisible until the seek to `sourceTime` has completed, so
    /// a frame the player happened to have before that never shows over the tile; the
    /// poster underneath only joins once the flight has started, so that while the card
    /// still sits transparent over the visible tile, nothing covers it.
    @ViewBuilder
    private func cardLayer(destination: CGRect, focus: CGRect) -> some View {
        ZStack {
            if hasStartedOpenFlight {
                poster(in: focus)
            }
            // The same placement the editor's stage uses, from a marker of the same size:
            // the surface itself hides the player until the displayed size is known, so no
            // guessed geometry ever shows over the tile before `prepare()` finishes.
            ClipEditorVideoSurface(
                player: viewModel.player,
                geometry: viewModel.previewOverlay,
                marker: focus,
                adjustment: viewModel.cropAdjustment,
                onReadyForDisplay: surfaceDidBecomeReady)
            .opacity(isSeekedToSource ? 1 : 0)
        }
        .frame(width: destination.width, height: destination.height)
        // Lets a UI test read this layer's laid-out (pre-transform, i.e. settled)
        // frame — accessibility reports geometry independent of opacity — to verify it
        // tracks the real destination rather than a placeholder. It cannot see the live
        // transform.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("expansion-card")
        .position(x: destination.midX, y: destination.midY)
    }

    /// The tile's poster at the crop marker — it's the crop rect's content, already
    /// adjusted the way the tile shows it — or the tile's placeholder fill without one.
    @ViewBuilder
    private func poster(in focus: CGRect) -> some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1, orientation: .up)
                .resizable()
                .scaledToFill()
                .frame(width: focus.width, height: focus.height)
                .clipped()
                .position(x: focus.midX, y: focus.midY)
        } else {
            Color(.quaternarySystemFill)
        }
    }

    /// Writes `hasLanded` with animations disabled, so the card/editor swap it drives is
    /// an instant cut even when it lands in the same update as an animated `progress`
    /// change (a close's first frame).
    private func setLanded(_ landed: Bool) {
        guard hasLanded != landed else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { hasLanded = landed }
    }

    /// A placeholder marker for the brief window before `ClipEditorView`'s own preference
    /// report arrives: the marker depends only on the editor's layout, not on media, so the
    /// real frame lands with the editor's first layout pass — before the flight, which waits
    /// on the player, can start. The same marker rule over a rough stage band, so even that
    /// first frame is close.
    private func fallbackMarker(in destination: CGRect) -> CGRect {
        let stage = destination.insetBy(dx: 0, dy: destination.height * 0.15)
        return ClipEditorStage.markerRect(in: stage, aspectRatio: viewModel.targetAspectRatio)
    }

    /// The frame a closing flight scrubs to: `sourceTime` when the tile will show the
    /// same clip it did at the tap — its loop resumes from where it paused — or the new
    /// window's midpoint, the tile's new poster frame, when an edit means the tile
    /// rebuilds anyway.
    private var landingTime: TimeInterval {
        let originalWindow = viewModel.duration.map {
            ClipEditorViewModel.clamped(window: source.window, to: $0)
        } ?? source.window
        let isUnchanged = viewModel.window == originalWindow
            && viewModel.cropRect == source.cropRect
            && viewModel.cropAdjustment == source.cropAdjustment
        return isUnchanged ? sourceTime : (viewModel.window.startTime + viewModel.window.endTime) / 2
    }

    // MARK: - Opening

    /// Seeks the shared player to `sourceTime` and starts the flight once the card can
    /// show that frame — or after `surfaceReadinessTimeout`, with the poster standing in.
    private func armOpenFlight() {
        Task { @MainActor in
            await viewModel.holdPlayback(at: sourceTime)
            isSeekedToSource = true
            startOpenFlightIfReady(force: false)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(surfaceReadinessTimeout * 1_000_000_000))
            startOpenFlightIfReady(force: true)
        }
    }

    private func surfaceDidBecomeReady() {
        isSurfaceReady = true
        startOpenFlightIfReady(force: false)
    }

    private func startOpenFlightIfReady(force: Bool) {
        guard !hasStartedOpenFlight, force || (isSeekedToSource && isSurfaceReady) else { return }
        hasStartedOpenFlight = true
        onFlightStarted()
        ExpansionFlightGeometry.animateFlight({ progress = 1 }, completion: {
            guard !isClosing else { return }
            setLanded(true)
            viewModel.releasePlayback()
        })
        scrubber.animate(from: sourceTime, to: viewModel.window.startTime, duration: flightDuration)
    }

    // MARK: - Closing

    /// Drives `progress` directly from drag translation — the same geometry math the
    /// open/close flights use, just sampled live instead of animated — and scrubs the
    /// player in step with it. Per the real Photos app, there's no real distance
    /// threshold on release: any downward-released drag (or one still moving down)
    /// commits; only a drag released while still moving upward snaps back.
    ///
    /// A committing release is the editor's back-navigation by another route
    /// (`docs/UIUX.md` § "Clip Detail / Editor"), so it hands the edits back through
    /// `onCommit` exactly as `ClipEditorView`'s own back chevron does before closing —
    /// the editor holds its draft in view state until it's left, and nothing else
    /// delivers it. A cancelled drag commits nothing: the editor stays open.
    private var dismissDragGesture: AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 8)
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    acceptsDestinationUpdates = false
                    setLanded(false)
                    let origin = dragScrubOrigin ?? viewModel.beginPresenterScrub()
                    dragScrubOrigin = origin
                    let travel = max(0, value.translation.height)
                    progress = 1 - min(travel / dismissTravel, 1)
                    scrubber.request(origin + (landingTime - origin) * (1 - progress))
                }
                .onEnded { value in
                    didHandleDragEnd = true
                    let committing = value.translation.height > 12
                        || value.predictedEndTranslation.height > value.translation.height
                    if committing {
                        onCommit(viewModel.result)
                        close()
                    } else {
                        cancelDrag()
                    }
                }
        )
    }

    /// Flies back to fully open and scrubs the player back to the frame the drag
    /// started on, then resumes playback if the user hadn't paused it.
    private func cancelDrag() {
        if progress < 1 {
            ExpansionFlightGeometry.animateFlight({ progress = 1 }, completion: {
                // Not if another drag has started, or a close, while this snap-back ran.
                guard dragTranslation == nil, !isClosing else { return }
                setLanded(true)
            })
        } else {
            // The drag never moved the card (it only ever went up), so there is nothing to
            // animate and no completion to wait for.
            setLanded(true)
        }
        guard let origin = dragScrubOrigin else { return }
        dragScrubOrigin = nil
        scrubber.animate(from: viewModel.currentTime, to: origin, duration: flightDuration)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(flightDuration * 1_000_000_000))
            guard dragScrubOrigin == nil, !isClosing else { return }
            viewModel.endPresenterScrub()
        }
    }

    /// Reverse flight back to the tile, scrubbing the player from the frame it's showing
    /// to `landingTime`, then — once it's visually landed — the actual dismiss.
    /// `Transaction.disablesAnimations` alone leaves a residual slide visible: it
    /// suppresses SwiftUI's own animation system but not the UIKit `dismiss(animated:)`
    /// call that backs `fullScreenCover` underneath, so the already-landed card would
    /// visibly slide off with the system's own cover-dismiss transition —
    /// `UIView.setAnimationsEnabled(false)` reaches that layer directly, the same fix
    /// `HomeView.presentSlot` uses on the opening side. Re-enabling it needs a longer hold
    /// than that opening-side fix does, though: per `HomeExpansionContainer.close()`'s own
    /// doc comment, frame-by-frame inspection of screen recordings showed UIKit scheduling
    /// `dismiss(animated:)`'s transition later than `present(animated:)`'s, so re-enabling
    /// on just the next run loop turn still let the slide play out.
    private func close() {
        acceptsDestinationUpdates = false
        isClosing = true
        setLanded(false)
        let from = viewModel.beginPresenterScrub()
        dragScrubOrigin = nil
        withAnimation(.easeInOut(duration: flightDuration)) { progress = 0 }
        scrubber.animate(from: from, to: landingTime, duration: flightDuration)
        dismissAfterLanding(delay: flightDuration + 0.05)
    }

    /// Delete's own close: a plain fade in place, not a flight back to `sourceFrame`
    /// — see `deleteFadeOpacity`'s own comment for why.
    private func closeForDelete() {
        acceptsDestinationUpdates = false
        isClosing = true
        scrubber.cancel()
        // Back onto the card for the fade, as `close()` does: under the fade's opacity the
        // editor's frosted surround can't blur, and would show the frame outside the
        // marker sharp; the card is the marker alone.
        setLanded(false)
        withAnimation(.easeOut(duration: 0.22)) { deleteFadeOpacity = 0 }
        dismissAfterLanding(delay: 0.22)
    }

    /// Dismisses once the flight has visually landed — `delay` after it began, and never
    /// before the scrub's final seek has put the landing frame on screen.
    private func dismissAfterLanding(delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await scrubber.waitUntilDone()
            UIView.setAnimationsEnabled(false)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UIView.setAnimationsEnabled(true)
            }
        }
    }
}
