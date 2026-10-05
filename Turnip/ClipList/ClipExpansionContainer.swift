import SwiftUI

/// The tapped tile's Photos-style open/close flight into Turnip's crop-hole editor.
///
/// Two layers share one `progress` clock (`0` = exactly at the tile, `1` = fully open).
/// A "card" carries the geometry the whole way: the editor's own video surface
/// (`ClipEditorVideoSurface`, rendering the very same `AVPlayer` the editor renders),
/// laid out at the editor's settled preview frame and shown through a window that
/// uncrops from the part the tile showed — the crop rect's center square — to the whole
/// frame, scaled uniformly so the picture is cropped as it grows, never stretched
/// (`ExpansionFlightGeometry`). The real `ClipEditorView` is hidden for the entire
/// flight and cut in instantly once the card has arrived (`crossfadeThreshold`); since
/// both layers draw the same player at the same frame in the same place, the cut is
/// invisible.
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
    /// The editor's real preview frame, as `ClipEditorPreviewFramePreferenceKey` reports
    /// it. Live through the opening flight — a newly mounted view's first reports settle
    /// over a few passes — and frozen from the moment a close can begin, see
    /// `acceptsDestinationUpdates`.
    @State private var measuredDestination: CGRect?
    /// Gates `measuredDestination` updates: `true` through the opening flight, `false`
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

    /// How long the open and close flights take, wall-clock. A timing curve with an
    /// explicit duration rather than a spring, so the visible growth lasts exactly this
    /// long instead of a spring's long tail.
    private let flightDuration: TimeInterval = 0.35
    /// How long the opening flight waits for the card's video surface before starting
    /// anyway, with the poster thumbnail standing in for a frame that never came.
    private let surfaceReadinessTimeout: TimeInterval = 0.3
    /// Below this, the real editor is invisible and the card alone carries the
    /// geometry; at/above it, the editor is. Effectively `1`: the swap has to happen
    /// where the card's window equals the editor's settled frame, which is only at
    /// `progress == 1`. Fractionally under `1` only so an interactive drag's very first
    /// touch-move (`progress = 1 - travel / dismissTravel`) already hands back to the card.
    private let crossfadeThreshold: CGFloat = 0.999
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
            let destination = measuredDestination ?? fallbackDestination(in: screen.size)
            // The crop rect in the card's own coordinates: what the tile shows, and so the
            // part of the frame the card's window starts on.
            let focus = viewModel.cropRect.denormalized(in: destination.size)
            let editorOpacity = editorOpacity(for: progress)

            ZStack {
                Color(.systemBackground)
                    .opacity(progress)
                    .ignoresSafeArea()

                NavigationStack {
                    ClipEditorView(
                        viewModel: viewModel,
                        onCommit: onCommit,
                        onDelete: onDelete,
                        onRequestClose: close,
                        onRequestDeleteClose: closeForDelete,
                        dismissGesture: dismissDragGesture)
                }
                .frame(width: screen.size.width, height: screen.size.height)
                .modifier(ExpansionCrossfadeCut(
                    progress: progress, threshold: crossfadeThreshold, visibleAboveThreshold: true))
                .allowsHitTesting(editorOpacity > 0.99)
                .onPreferenceChange(ClipEditorPreviewFramePreferenceKey.self) { frame in
                    guard acceptsDestinationUpdates, frame != .zero else { return }
                    measuredDestination = frame
                }

                cardLayer(destination: destination, focus: focus)
                    .modifier(ExpansionCrossfadeCut(
                        progress: progress, threshold: crossfadeThreshold, visibleAboveThreshold: false))
                    // Both outside `ExpansionCrossfadeCut`, not inside it: its
                    // animation-suppressing transaction applies to its whole subtree, so an
                    // `Animatable` nested under it never gets per-frame values and snaps
                    // straight to its target. The layer these wrap (post-`.position`) has
                    // its origin at the screen's, which both rely on.
                    .clipShape(ExpansionFlightClip(
                        progress: progress, sourceFrame: sourceFrame, destination: destination,
                        focus: focus, sourceCornerRadius: sourceCornerRadius))
                    .modifier(ExpansionFlightEffect(
                        progress: progress, sourceFrame: sourceFrame, destination: destination, focus: focus))
                    .allowsHitTesting(editorOpacity < 0.99)
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

    /// Laid out at `destination`'s size/position — fixed, not animated — with
    /// `ExpansionFlightClip`/`ExpansionFlightEffect` doing the actual flight on top.
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
            ClipEditorVideoSurface(
                player: viewModel.player,
                cropCenter: UnitPoint(
                    x: CGFloat(viewModel.cropRect.minX + viewModel.cropRect.maxX) / 2,
                    y: CGFloat(viewModel.cropRect.minY + viewModel.cropRect.maxY) / 2),
                adjustment: viewModel.cropAdjustment,
                // No offset at all until the displayed size is known: scale and rotation
                // are unit-agnostic, but a pan converted at a guessed scale would throw
                // the picture off the card for the frames before `prepare()` finishes.
                pointsPerDisplayedPixel: viewModel.previewOverlay.map { destination.width / $0.videoSize.width } ?? 0,
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

    /// The tile's poster at the crop rect — it's the crop rect's content, already
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

    /// Only feeds `allowsHitTesting` — see `ExpansionCrossfadeCut` for why a plain
    /// computed property can't drive the layers' actual visibility. Hit-testing only
    /// has to be right once the flight has fully committed to a direction, which the
    /// two endpoints `body` sees are enough for.
    private func editorOpacity(for progress: CGFloat) -> CGFloat {
        progress >= crossfadeThreshold ? 1 : 0
    }

    /// A placeholder destination for the brief window before `ClipEditorView`'s own
    /// preference report arrives (its aspect ratio needs the asset's track info,
    /// loaded asynchronously in `prepare()`) — close enough that the retarget once the
    /// real frame lands isn't a visible jump.
    private func fallbackDestination(in size: CGSize) -> CGRect {
        let side = size.width - 32
        return CGRect(x: 16, y: 100, width: side, height: side)
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
        withAnimation(.easeInOut(duration: flightDuration)) { progress = 1 }
        scrubber.animate(from: sourceTime, to: viewModel.window.startTime, duration: flightDuration)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(flightDuration * 1_000_000_000))
            guard !isClosing else { return }
            viewModel.releasePlayback()
        }
    }

    // MARK: - Closing

    /// Drives `progress` directly from drag translation — the same geometry math the
    /// open/close flights use, just sampled live instead of animated — and scrubs the
    /// player in step with it. Per the real Photos app, there's no real distance
    /// threshold on release: any downward-released drag (or one still moving down)
    /// commits; only a drag released while still moving upward snaps back.
    private var dismissDragGesture: AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 8)
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    acceptsDestinationUpdates = false
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
        withAnimation(.easeInOut(duration: flightDuration)) { progress = 1 }
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
