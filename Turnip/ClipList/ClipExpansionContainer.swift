import SwiftUI

/// The tapped tile's Photos-style open/close flight, adapted for Turnip's crop-hole
/// editor — whose settled content is a different composition (full frame plus a
/// dimmed crop surround) rather than literally the same image Photos keeps on screen
/// throughout. Two layers share one `progress` clock (`0` = exactly at the tile,
/// `1` = fully open): a lightweight "card" (the tile's own cropped thumbnail) carries
/// the geometry the whole way, while the real `ClipEditorView` is hidden entirely
/// until the last stretch of travel, then cut in instantly, with no cross-dissolve —
/// late enough that its toolbar/trim-slider text never has to be legible mid-shrink
/// (`crossfadeThreshold`), but an instant swap rather than a fade so neither layer is
/// ever seen at partial opacity.
///
/// `progress` is driven by a spring for the tap-to-open and back-button-close paths,
/// and 1:1 by drag translation for the interactive swipe-to-dismiss — the same
/// geometry/opacity math serves both, so there's no separate "interactive" branch.
/// The swipe-to-dismiss gesture is handed to `ClipEditorView` to attach on its own
/// root view's background, rather than living out here behind it: `NavigationStack`
/// is backed by a real `UIViewController`, and a touch landing on *its* empty space
/// resolves to that hosting view, not through to a SwiftUI sibling behind it in this
/// `ZStack` — a gesture out here would never fire at all. Planted inside the same
/// content `NavigationStack` hosts, it only fires where the editor's own crop-drag/
/// trim-slider gestures don't claim the touch first — the "outside the video" dismiss
/// zone this feature was scoped to.
struct ClipExpansionContainer: View {
    /// The tapped tile's on-screen frame at the moment of the tap, in global
    /// coordinate space — the flight's start (opening) and end (closing) point.
    let sourceFrame: CGRect
    /// The tile's already-decoded poster frame, so the flying card has something to
    /// show instantly instead of waiting on a second image load.
    let thumbnail: CGImage?
    let source: ClipEditorSource
    let onCommit: (ClipEditorResult) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress: CGFloat = 0
    /// The editor's real, untransformed preview frame — recovered from
    /// `ClipEditorPreviewFramePreferenceKey`'s report by dividing out this container's
    /// own `.scaleEffect`/`.offset`, rather than used as reported. `previewSection`'s
    /// `GeometryReader` sits *inside* that transform, so its raw `.global` frame is the
    /// *transformed* position, not the editor's natural one — using it directly would
    /// feed back on itself (the transform moves the measured frame, which moves
    /// `destination`, which moves the transform...), which a previous version dodged by
    /// only ever accepting a report once `progress` had already settled near 1 (where
    /// the transform is ~identity). That meant the destination this container grew
    /// *toward* stayed a placeholder guess for the entire opening flight, and a closing
    /// flight's start point was only ever an approximation (whatever the transform's
    /// small residual error happened to be at the moment it crossed the settle
    /// threshold) rather than the editor's true frame. Dividing out the known transform
    /// recovers the true frame from *any* report, so it can stay live for the opening
    /// flight — necessary there: the very first reports, taken before
    /// `editorScale` has grown much past its starting value, are still visibly off (an
    /// early-mount report doesn't yet reflect the real composited transform), and only
    /// settle to the true frame after a few more arrive. `acceptsDestinationUpdates`
    /// below stops accepting new reports once any close begins, though — see that
    /// property's own doc comment for why staying live for the *whole* lifetime
    /// (what this used to do) doesn't just risk working for longer than it needs to.
    @State private var measuredDestination: CGRect?
    /// Gates `measuredDestination` updates: `true` through the opening flight (where
    /// convergence from a placeholder-ish early report to the true frame is the actual
    /// point of dividing out the transform live — see `measuredDestination`'s own doc
    /// comment), `false` from the first touch-move of an interactive drag, or from the
    /// moment `close()`/`closeForDelete()` runs, whichever comes first — i.e. for the rest
    /// of this container's life, cancelled drag included, once the user could possibly be
    /// leaving.
    ///
    /// Why: unlike `HomeExpansionContainer`, which applies no transform to its own
    /// content, this container's `editorScale`/`editorOffsetX`/`editorOffsetY` (what
    /// `measuredDestination` is divided out of) are themselves computed *from*
    /// `measuredDestination` — self-referential. At a steady `progress` (fully open, fully
    /// closed) that has one chance to converge and then goes quiet, since
    /// `previewSection`'s on-screen frame stops moving and no more reports arrive. While
    /// `progress` is animating or being dragged, though, it keeps moving for the whole
    /// transition, through this exact same `onPreferenceChange` handler every intermediate
    /// frame, so a self-referential loop there has far more chances to compound than it
    /// does at a steady state.
    ///
    /// What's actually confirmed, from a user's real device, where the old always-live
    /// version of this code froze on every close (never reproduced on the simulator): the
    /// main thread livelocked and never recovered, and two debugger pauses taken a few
    /// seconds apart each landed inside a `CATransaction` commit — one inside SwiftUI's own
    /// graph update, the other 25 frames into a `CALayer` tree walk — with no app code in
    /// either stack. That's real evidence of a genuine, unrecovering main-thread livelock
    /// triggered by closing the editor; it is not a confirmation that *this specific
    /// self-reference* is the mechanism (two samples can't show that, and the fix below is
    /// inference from the code's structure, not from stepping through the actual loop). If
    /// a user's device still freezes after this change, that inference was wrong and the
    /// real cause is still out there.
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
    /// Delete fades the whole view out in place instead of flying to `sourceFrame`:
    /// by the time this runs, that tile's slot in the grid holds a different item (or
    /// nothing), so flying there would land in the wrong spot.
    @State private var deleteFadeOpacity: CGFloat = 1

    /// Below this, the real editor is invisible and the card alone carries the
    /// geometry; above it, the two crossfade.
    private let crossfadeThreshold: CGFloat = 0.85
    /// Downward drag distance, in points, that fully closes the view.
    private let dismissTravel: CGFloat = 420
    /// The tile's own corner radius (`ClipCardView.tile`'s `clipShape`) — the flying
    /// card's radius eases to 0 as it grows, matching the editor's sharp-cornered
    /// preview.
    private let sourceCornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { screen in
            let destination = measuredDestination ?? fallbackDestination(in: screen.size)
            let rect = currentRect(destination: destination)
            let editorOpacity = editorOpacity(for: progress)
            let editorScale = rect.width / max(destination.width, 1)
            let editorOffsetX = rect.minX - destination.minX * editorScale
            let editorOffsetY = rect.minY - destination.minY * editorScale
            let cornerRadius = sourceCornerRadius * (1 - progress)

            ZStack {
                Color(.systemBackground)
                    .opacity(progress)
                    .ignoresSafeArea()

                NavigationStack {
                    ClipEditorView(
                        source: source,
                        onCommit: onCommit,
                        onDelete: onDelete,
                        onRequestClose: close,
                        onRequestDeleteClose: closeForDelete,
                        dismissGesture: dismissDragGesture)
                }
                .frame(width: screen.size.width, height: screen.size.height)
                .scaleEffect(editorScale, anchor: .topLeading)
                .offset(x: editorOffsetX, y: editorOffsetY)
                .opacity(editorOpacity)
                .allowsHitTesting(editorOpacity > 0.99)
                .onPreferenceChange(ClipEditorPreviewFramePreferenceKey.self) { frame in
                    // See `acceptsDestinationUpdates`'s own doc comment for why this stops
                    // once a close begins instead of staying live for the whole lifetime.
                    guard acceptsDestinationUpdates, frame != .zero, editorScale > 0 else { return }
                    measuredDestination = CGRect(
                        x: (frame.minX - editorOffsetX) / editorScale,
                        y: (frame.minY - editorOffsetY) / editorScale,
                        width: frame.width / editorScale,
                        height: frame.height / editorScale)
                }

                cardLayer(rect: rect)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .opacity(1 - editorOpacity)
                    .allowsHitTesting(editorOpacity < 0.99)
            }
            .opacity(deleteFadeOpacity)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { progress = 1 }
        }
        .onChange(of: dragTranslation != nil) { isDraggingNow in
            guard !isDraggingNow else { return }
            guard !didHandleDragEnd else {
                didHandleDragEnd = false
                return
            }
            // `onEnded` never ran (system-cancelled) — fall back to the same
            // cancel-spring a normal non-committing release would use.
            withAnimation(.spring(response: 0.29, dampingFraction: 0.9)) { progress = 1 }
        }
    }

    @ViewBuilder
    private func cardLayer(rect: CGRect) -> some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.quaternarySystemFill)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .position(x: rect.midX, y: rect.midY)
        // Lets a UI test read this layer's live laid-out frame (accessibility reports
        // geometry independent of its current opacity) to verify it tracks the real
        // destination rather than a placeholder — see `docs/EXPANSION_TRANSITIONS.md`'s
        // "Measuring the destination without a race or a feedback loop".
        .accessibilityIdentifier("expansion-card")
    }

    /// A hard cut, not a fade: below `crossfadeThreshold` the card is the only thing
    /// visible, at/above it the real editor is — the two never co-fade at partial
    /// opacity, so the swap reads as instant rather than a dissolve.
    private func editorOpacity(for progress: CGFloat) -> CGFloat {
        progress >= crossfadeThreshold ? 1 : 0
    }

    /// Linear interpolation between `sourceFrame` and `destination`, lerping the
    /// center and size separately rather than the raw `minX`/`minY` so the card grows
    /// from its own middle instead of its corner.
    private func currentRect(destination: CGRect) -> CGRect {
        let width = sourceFrame.width + (destination.width - sourceFrame.width) * progress
        let height = sourceFrame.height + (destination.height - sourceFrame.height) * progress
        let midX = sourceFrame.midX + (destination.midX - sourceFrame.midX) * progress
        let midY = sourceFrame.midY + (destination.midY - sourceFrame.midY) * progress
        return CGRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height)
    }

    /// A placeholder destination for the brief window before `ClipEditorView`'s own
    /// preference report arrives (its aspect ratio needs the asset's track info,
    /// loaded asynchronously in `prepare()`) — close enough that the retarget once the
    /// real frame lands isn't a visible jump.
    private func fallbackDestination(in size: CGSize) -> CGRect {
        let side = size.width - 32
        return CGRect(x: 16, y: 100, width: side, height: side)
    }

    /// Drives `progress` directly from drag translation — the same geometry/opacity
    /// math the open/close springs use, just sampled live instead of animated. Per
    /// the real Photos app, there's no real distance threshold on release: any
    /// downward-released drag (or one still moving down) commits; only a drag
    /// released while still moving upward snaps back.
    private var dismissDragGesture: AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 8)
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    // Stops `measuredDestination` updates for the rest of this container's
                    // lifetime, cancel or commit: see `acceptsDestinationUpdates`'s own doc
                    // comment for why a live interactive drag is unstable — the opening
                    // flight converged long before dragging was possible, so there's no
                    // destination left to lose by not remeasuring during or after one.
                    acceptsDestinationUpdates = false
                    let travel = max(0, value.translation.height)
                    progress = 1 - min(travel / dismissTravel, 1)
                }
                .onEnded { value in
                    didHandleDragEnd = true
                    let committing = value.translation.height > 12
                        || value.predictedEndTranslation.height > value.translation.height
                    if committing {
                        close()
                    } else {
                        withAnimation(.spring(response: 0.29, dampingFraction: 0.9)) { progress = 1 }
                    }
                }
        )
    }

    /// Reverse flight back to the tile, then — once it's visually landed — the actual
    /// dismiss. `Transaction.disablesAnimations` alone leaves a residual slide visible:
    /// it suppresses SwiftUI's own animation system but not the UIKit `dismiss(animated:)`
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { progress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            UIView.setAnimationsEnabled(false)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UIView.setAnimationsEnabled(true)
            }
        }
    }

    /// Delete's own close: a plain fade in place, not a flight back to `sourceFrame`
    /// — see `deleteFadeOpacity`'s own comment for why. Same `setAnimationsEnabled`
    /// guard as `close()`, for the same reason.
    private func closeForDelete() {
        acceptsDestinationUpdates = false
        withAnimation(.easeOut(duration: 0.22)) { deleteFadeOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
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
