import SwiftUI

/// Home's Photos-style open/close flight: a tapped grid tile flies open into its full-screen
/// destination (`ProcessingView`, or `ClipListView` directly for a video the camera already
/// analyzed), and back-button/swipe-down close flies the reverse, landing on the tile for
/// whichever video is actually on screen — not necessarily the one first tapped, since
/// `ProcessingView`'s own swipe-to-browse can move to a neighbor first.
///
/// Structurally a sibling of `ClipExpansionContainer` rather than a shared generic: that
/// container's two-layer card/real-content crossfade exists because the editor's settled
/// content (full frame + dimmed crop surround) is a different *composition* than the tile's
/// cropped square. The destination here defaults to the full screen edge-to-edge
/// (`ProcessingView`/`ClipListView` both already `ignoresSafeArea()`), but — unlike
/// `ClipExpansionContainer`, whose destination is always the editor's own fixed-aspect preview
/// — Home's destination can be a *letterboxed* video: `ProcessingView`'s player uses
/// `.resizeAspect` gravity, so a video whose aspect ratio doesn't match the screen's only
/// occupies a smaller centered rect within it. `measuredDestination` below corrects for that
/// once `ProcessingView` reports its real on-screen video rect; `ClipListView` as a destination
/// never reports one (it has no single video frame, just its own grid), so the full-screen
/// default stands for that case. This container gains two more things `ClipExpansionContainer`
/// didn't need: a `sourceFrame` that's a live lookup rather than a one-shot capture (the close
/// must land on whichever tile is current after a browse, not the one first tapped), and a
/// dismiss gesture driven *into* it from the destination's own existing swipe
/// (`ProcessingView.DismissGestureHooks`) rather than one it owns itself.
/// What a destination wires into its own close affordances — split out from
/// `HomeExpansionContainer` itself (rather than nested) so a destination-building function can
/// name this parameter's type without first naming the container's own `Content` generic.
/// `onRequestClose` covers a plain back button; `dismissTranslationChanged`/`dismissEnded`/
/// `dismissCancelled` cover a destination with its own live vertical-drag gesture
/// (`ProcessingView`) — a destination without one (`ClipListView`) simply never calls them.
struct HomeExpansionCloseHandlers {
    let onRequestClose: () -> Void
    let dismissTranslationChanged: (CGFloat) -> Void
    let dismissEnded: (_ translation: CGFloat, _ predictedTranslation: CGFloat) -> Void
    let dismissCancelled: () -> Void
}

struct HomeExpansionContainer<Content: View>: View {
    /// A live lookup of the current video's tile frame (global space) — re-evaluated at open,
    /// at close, and continuously while a live dismiss drag is in progress, so a close after
    /// browsing to a neighbor lands on *that* tile. `nil` while the tile isn't on screen (the
    /// grid is scrolling it into place, or it's off the loaded prefix); the fallback destination
    /// below stands in until it resolves.
    let sourceFrame: () -> CGRect?
    /// The tapped tile's already-decoded thumbnail, so the flying card has something to show
    /// instantly. Re-supplied (not locked to the first tap) when browsing to a neighbor whose
    /// thumbnail is already cached.
    let thumbnail: UIImage?
    /// Builds the destination content, given the handlers it should wire into its own
    /// back-button/dismiss-gesture. `ProcessingView` (via its `onRequestClose`/
    /// `dismissGestureHooks`) or a plain `NavigationStack { ClipListView(...) }` (via
    /// `onRequestClose` alone — it has no built-in swipe-to-dismiss of its own) both fit this
    /// shape.
    @ViewBuilder let content: (HomeExpansionCloseHandlers) -> Content

    @Environment(\.dismiss) private var dismiss
    @State private var progress: CGFloat = 0
    /// Latches `sourceFrame()`'s value the instant a non-interactive close (back button, or a
    /// committed swipe-to-dismiss) begins, then `currentRect` prefers this over the live lookup
    /// for the rest of that flight — the same reasoning `ClipExpansionContainer` locks its own
    /// `measuredDestination`: once the flight is no longer driven by a live gesture, there's no
    /// reason for its endpoint to keep tracking a value that could still change underneath it.
    /// `sourceFrame()` stays live during an in-progress interactive drag (needed for the
    /// browse-mid-drag case the type's own doc comment describes). Reset not needed: this
    /// container is a fresh instance each time it's presented.
    @State private var lockedSourceFrame: CGRect?
    /// `ProcessingView`'s real, letterboxed video rect (global space), once it's reported one
    /// via `ProcessingVideoFramePreferenceKey` — `nil` until then, and the full-screen default
    /// in `body` stands in. Simply keeps the latest non-zero report rather than locking after
    /// the first one: unlike `ClipExpansionContainer`'s `measuredDestination`, this container
    /// applies no transform to `content` that the measurement could feed back into (only an
    /// opacity crossfade), and — because `sourceFrame` above is deliberately live for the same
    /// reason — this needs to stay live too: browsing to a neighbor with a different aspect
    /// ratio must retarget this, not keep flying toward the first video's letterbox rect.
    @State private var measuredDestination: CGRect?
    /// Below this, the real destination is invisible and the card alone carries the geometry;
    /// above it, the two crossfade. See `ClipExpansionContainer`'s own constant for why: late
    /// enough that chrome/controls never have to be legible mid-shrink.
    private let crossfadeThreshold: CGFloat = 0.85
    private let dismissTravel: CGFloat = 420
    private let sourceCornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { screen in
            let destination = measuredDestination ?? CGRect(origin: .zero, size: screen.size)
            let rect = currentRect(destination: destination)
            let contentOpacity = self.contentOpacity(for: progress)
            let cornerRadius = sourceCornerRadius * (1 - progress)

            ZStack {
                Color.black
                    .opacity(progress)
                    .ignoresSafeArea()

                content(closeHandlers)
                    .opacity(contentOpacity)
                    .allowsHitTesting(contentOpacity > 0.99)
                    .onPreferenceChange(ProcessingVideoFramePreferenceKey.self) { frame in
                        guard frame != .zero else { return }
                        measuredDestination = frame
                    }

                cardLayer(rect: rect)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .opacity(1 - contentOpacity)
                    .allowsHitTesting(contentOpacity < 0.99)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { progress = 1 }
        }
    }

    private var closeHandlers: HomeExpansionCloseHandlers {
        HomeExpansionCloseHandlers(
            onRequestClose: close,
            dismissTranslationChanged: { translation in
                let travel = max(0, translation)
                progress = 1 - min(travel / dismissTravel, 1)
            },
            dismissEnded: { translation, predictedTranslation in
                let committing = translation > 12 || predictedTranslation > translation
                if committing {
                    close()
                } else {
                    withAnimation(.spring(response: 0.29, dampingFraction: 0.9)) { progress = 1 }
                }
            },
            dismissCancelled: {
                withAnimation(.spring(response: 0.29, dampingFraction: 0.9)) { progress = 1 }
            })
    }

    @ViewBuilder
    private func cardLayer(rect: CGRect) -> some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.quaternarySystemFill)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .position(x: rect.midX, y: rect.midY)
    }

    private func contentOpacity(for progress: CGFloat) -> CGFloat {
        max(0, min(1, (progress - crossfadeThreshold) / (1 - crossfadeThreshold)))
    }

    /// Linear interpolation between the source frame (falling back to a centered, slightly-inset
    /// square if the tile isn't on screen right now) and `destination` (the full screen, unless
    /// `measuredDestination` has narrowed it to the real letterboxed video rect), lerping
    /// center and size separately so the card grows from its own middle. The source is
    /// `lockedSourceFrame` once `close()` has latched one, else the live `sourceFrame()`.
    private func currentRect(destination: CGRect) -> CGRect {
        let source = lockedSourceFrame ?? sourceFrame() ?? fallbackSourceFrame(in: destination.size)
        let width = source.width + (destination.width - source.width) * progress
        let height = source.height + (destination.height - source.height) * progress
        let midX = source.midX + (destination.midX - source.midX) * progress
        let midY = source.midY + (destination.midY - source.midY) * progress
        return CGRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height)
    }

    private func fallbackSourceFrame(in size: CGSize) -> CGRect {
        let side = size.width * 0.3
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    /// Reverse flight back to the tile, then — once it's visually landed — the actual dismiss.
    /// `Transaction.disablesAnimations` alone leaves a residual slide visible: it suppresses
    /// SwiftUI's own animation system but not the UIKit `dismiss(animated:)` call that backs
    /// `fullScreenCover` underneath, so the already-landed card visibly slides off-screen with
    /// the system's own cover-dismiss transition — the same issue `HomeView.presentSlot` hit on
    /// the opening side, fixed there with `UIView.setAnimationsEnabled(false)`.
    ///
    /// Applying that same fix here needed a longer hold than `presentSlot`'s: re-enabling on
    /// the very next run loop turn (as `presentSlot` does) was NOT enough — frame-by-frame
    /// inspection of screen recordings showed the slide still playing out over several hundred
    /// more milliseconds, meaning UIKit schedules `dismiss(animated:)`'s transition later than
    /// `present(animated:)`'s. Re-enabling after this delay instead reliably suppressed it
    /// across multiple recorded runs; shorter delays (one run loop turn, matching `presentSlot`)
    /// did not.
    private func close() {
        lockedSourceFrame = sourceFrame()
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
}
