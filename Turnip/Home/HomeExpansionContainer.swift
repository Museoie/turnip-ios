import AVFoundation
import SwiftUI

/// Home's Photos-style open/close flight: a tapped grid tile flies open into its full-screen
/// destination (`ProcessingView`, or `ClipListView` directly for a video the camera already
/// analyzed), and back-button/swipe-down close flies the reverse, landing on the tile for
/// whichever video is actually on screen — not necessarily the one first tapped, since
/// `ProcessingView`'s own swipe-to-browse can move to a neighbor first.
///
/// Structurally a sibling of `ClipExpansionContainer` rather than a shared generic: the two
/// share their render-time primitives (`ExpansionFlightGeometry` and friends) but differ in
/// what they fly between. Home's card is the tile's square thumbnail at the center of the
/// video's frame, with the full-frame poster and — once `ProcessingView` reports one — the
/// live player underneath it filling the rest, so the card uncrops from the tile's square
/// into the whole video as it grows and shows the video's current frame as it shrinks. The
/// destination defaults to the full screen edge-to-edge (`ProcessingView`/`ClipListView`
/// both already `ignoresSafeArea()`), but Home's destination can be a *letterboxed* video:
/// `ProcessingView`'s player uses `.resizeAspect` gravity, so a video whose aspect ratio
/// doesn't match the screen's only occupies a smaller centered rect within it.
/// `measuredDestination` below corrects for that once `ProcessingView` reports its real
/// on-screen video rect; until then, `fallbackDestination` stands in with the same letterbox
/// math run against `initialAspectRatio` (known synchronously, unlike the real measurement —
/// see that property's own doc comment), rather than the full screen, so the open flight
/// grows toward roughly the right rect from the first frame instead of only snapping to it
/// once the real measurement eventually lands. `ClipListView` as a destination never reports
/// a measurement (it has no single video frame, just its own grid), so the full-screen default
/// stands unchanged for that case. This container gains two more things `ClipExpansionContainer`
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
    /// The tapped tile's already-decoded thumbnail: the video's poster frame, center-cropped to
    /// the tile's square. Drawn at the center of the card's frame, so the card starts as exactly
    /// the tile. Re-supplied (not locked to the first tap) when browsing to a neighbor whose
    /// thumbnail is already cached.
    let thumbnail: UIImage?
    /// The same poster frame, full-frame (`ThumbnailLoader.cachedPoster`), when one has been
    /// loaded: fills the card around the tile's square so the uncropping growth reveals the
    /// rest of the picture. `nil` until `ProcessingView` has requested one; the live player
    /// fills in the same way once it reports.
    var poster: UIImage?
    /// The video's pixel dimensions (`PHAsset.pixelWidth`/`pixelHeight`), known synchronously
    /// from the tapped tile's own asset — used to letterbox the fallback destination (see
    /// `body`'s `destination`) while `measuredDestination` is still nil, instead of guessing the
    /// full screen. `nil` for a destination that never letterboxes (`ClipListView` directly, the
    /// camera-originated case) so that destination's correct full-screen default isn't
    /// second-guessed with an aspect ratio that doesn't apply to it. `ProcessingView`'s own
    /// measurement needs the asset's *track* to have loaded, which can't even start until a
    /// PhotoKit resolve that the Home doc comment notes "can be anywhere from instant to several
    /// seconds" has already finished — long enough to lose the race against the open flight
    /// every time, which is exactly what made the open flight grow toward the full screen
    /// instead of the destination's real letterboxed rect. `PHAsset.pixelWidth`/`pixelHeight`
    /// need no resolve at all (ordinary `PHAsset` metadata, already in hand from the grid), and
    /// already reflect display orientation — the same thing `ClipEditorViewModel.displayedSize`
    /// computes from `naturalSize` + `preferredTransform`, just without the async load.
    let initialAspectRatio: CGSize?
    /// Builds the destination content, given the handlers it should wire into its own
    /// back-button/dismiss-gesture. `ProcessingView` (via its `onRequestClose`/
    /// `dismissGestureHooks`) or a plain `NavigationStack { ClipListView(...) }` (via
    /// `onRequestClose` alone — it has no built-in swipe-to-dismiss of its own) both fit this
    /// shape.
    @ViewBuilder let content: (HomeExpansionCloseHandlers) -> Content

    @Environment(\.dismiss) private var dismiss
    @State private var progress: CGFloat = 0
    /// Latches `sourceFrame()`'s value the instant a non-interactive close (back button, or a
    /// committed swipe-to-dismiss) begins, then `body`'s own `source` resolution prefers this
    /// over the live lookup for the rest of that flight: once the flight is no longer driven by
    /// a live gesture, there's no reason for its endpoint to keep tracking a value that could
    /// still change underneath it. `sourceFrame()` stays live during an in-progress interactive
    /// drag (needed for the browse-mid-drag case the type's own doc comment describes). Reset not
    /// needed: this container is a fresh instance each time it's presented.
    @State private var lockedSourceFrame: CGRect?
    /// `ProcessingView`'s real, letterboxed video rect (global space), once it's reported one
    /// via `ProcessingVideoFramePreferenceKey` — `nil` until then, and the full-screen default
    /// in `body` stands in. Simply keeps the latest non-zero report rather than locking after
    /// the first one: this container applies no transform to `content` that the measurement
    /// could feed back into (only an opacity cut), and — because `sourceFrame` above is
    /// deliberately live for the same reason — this needs to stay live too: browsing to a
    /// neighbor with a different aspect ratio must retarget this, not keep flying toward the
    /// first video's letterbox rect.
    @State private var measuredDestination: CGRect?
    /// The destination's player, once `ProcessingView` reports it via
    /// `ProcessingPlayerPreferenceKey`: the card renders it too, so the card shows the very
    /// frame the destination is showing when one replaces the other, and a closing flight can
    /// scrub it back to the poster frame the tile shows. `nil` for a destination without a
    /// player (`ClipListView`, or `ProcessingView` still resolving its video).
    @State private var destinationPlayer: AVPlayer?
    @StateObject private var scrubber = FlightScrubber()
    /// Whether the player was playing when a presenter scrub began, so a cancelled dismiss
    /// drag can resume it; `nil` while no drag is in progress.
    @State private var dragScrubOrigin: (time: TimeInterval, wasPlaying: Bool)?
    /// Set by `close()`, so a cancelled drag's deferred resume that lands after the user
    /// has already started leaving doesn't restart the player under the closing scrub.
    @State private var isClosing = false
    /// Below this, the real destination is invisible and the card alone carries the geometry;
    /// at/above it, the destination is. See `ClipExpansionContainer`'s own constant for why
    /// this is effectively `1`.
    private let crossfadeThreshold: CGFloat = 0.999
    /// See `ClipExpansionContainer.flightDuration`.
    private let flightDuration: TimeInterval = 0.35
    private let dismissTravel: CGFloat = 420
    private let sourceCornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { screen in
            let destination = measuredDestination ?? fallbackDestination(in: screen.size)
            // Resolved once per body evaluation — the same source the flight effect below
            // flies from — not read live inside a render-time effect: a `GeometryEffect`'s own
            // parameters have to be plain values, not something it re-evaluates itself.
            let source = lockedSourceFrame ?? sourceFrame() ?? fallbackSourceFrame(in: destination.size)
            let focus = Self.centerSquare(of: destination.size)
            let contentOpacity = self.contentOpacity(for: progress)

            ZStack {
                Color.black
                    .opacity(progress)
                    .ignoresSafeArea()

                content(closeHandlers)
                    .modifier(ExpansionCrossfadeCut(
                        progress: progress, threshold: crossfadeThreshold, visibleAboveThreshold: true))
                    .allowsHitTesting(contentOpacity > 0.99)
                    .onPreferenceChange(ProcessingVideoFramePreferenceKey.self) { frame in
                        guard frame != .zero else { return }
                        measuredDestination = frame
                    }
                    .onPreferenceChange(ProcessingPlayerPreferenceKey.self) { handle in
                        destinationPlayer = handle.player
                        scrubber.seek = handle.player.map(FlightScrubber.exactSeek) ?? { _ in }
                    }

                cardLayer(destination: destination, focus: focus)
                    .modifier(ExpansionCrossfadeCut(
                        progress: progress, threshold: crossfadeThreshold, visibleAboveThreshold: false))
                    // Both outside `ExpansionCrossfadeCut`, deliberately — see the identical
                    // call site in `ClipExpansionContainer` for why the order is load-bearing.
                    .clipShape(ExpansionFlightClip(
                        progress: progress, sourceFrame: source, destination: destination,
                        focus: focus, sourceCornerRadius: sourceCornerRadius))
                    .modifier(ExpansionFlightEffect(
                        progress: progress, sourceFrame: source, destination: destination, focus: focus))
                    .allowsHitTesting(contentOpacity < 0.99)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: flightDuration)) { progress = 1 }
        }
    }

    private var closeHandlers: HomeExpansionCloseHandlers {
        HomeExpansionCloseHandlers(
            onRequestClose: close,
            dismissTranslationChanged: { translation in
                let travel = max(0, translation)
                progress = 1 - min(travel / dismissTravel, 1)
                let origin = dragScrubOrigin ?? beginPresenterScrub()
                dragScrubOrigin = origin
                scrubber.request(origin.time * progress)
            },
            dismissEnded: { translation, predictedTranslation in
                let committing = translation > 12 || predictedTranslation > translation
                if committing {
                    close()
                } else {
                    cancelDrag()
                }
            },
            dismissCancelled: cancelDrag)
    }

    /// Laid out at `destination`'s size/position — fixed, not animated — with
    /// `ExpansionFlightClip`/`ExpansionFlightEffect` doing the actual flight on top. Bottom
    /// to top: the tile's square thumbnail at the frame's center square (exactly what the
    /// tile shows, so the card starts as the tile), the full-frame poster where one has
    /// loaded, and the destination's live player once it has reported — each a picture of
    /// the same video, so whichever is on top at a given moment, the card reads as one.
    @ViewBuilder
    private func cardLayer(destination: CGRect, focus: CGRect) -> some View {
        ZStack {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.quaternarySystemFill)
                }
            }
            .frame(width: focus.width, height: focus.height)
            .clipped()
            .position(x: focus.midX, y: focus.midY)
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
                    .frame(width: destination.width, height: destination.height)
                    .clipped()
            }
            if let destinationPlayer {
                BareVideoPlayerView(player: destinationPlayer)
            }
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

    /// Only feeds `allowsHitTesting` — see `ExpansionCrossfadeCut` for why a plain computed
    /// property can't drive the layers' actual visibility. Hit-testing only has to be right
    /// once the flight has committed to a direction, which the two endpoints `body` sees are
    /// enough for.
    private func contentOpacity(for progress: CGFloat) -> CGFloat {
        progress >= crossfadeThreshold ? 1 : 0
    }

    /// The part of the video's frame a square grid tile shows: `ThumbnailLoader` requests
    /// tile images aspect-filled to the tile, which is the frame's center square.
    private static func centerSquare(of size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    private func fallbackSourceFrame(in size: CGSize) -> CGRect {
        let side = size.width * 0.3
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    /// The destination before `measuredDestination` has a real report: the known aspect ratio's
    /// letterboxed rect (matching what `ProcessingView` will eventually measure) when one's
    /// available, else the full screen — correct as-is for a destination that never letterboxes
    /// (`ClipListView` directly).
    private func fallbackDestination(in size: CGSize) -> CGRect {
        guard let initialAspectRatio, initialAspectRatio.width > 0, initialAspectRatio.height > 0
        else { return CGRect(origin: .zero, size: size) }
        return AVMakeRect(aspectRatio: initialAspectRatio, insideRect: CGRect(origin: .zero, size: size))
    }

    /// Pauses the destination's player for a closing flight or dismiss drag and returns the
    /// frame the scrub starts from, with whether it was playing so a cancelled drag can resume
    /// it. Harmless without a player: the scrub then has nothing to drive.
    private func beginPresenterScrub() -> (time: TimeInterval, wasPlaying: Bool) {
        guard let destinationPlayer else { return (0, false) }
        let wasPlaying = destinationPlayer.rate > 0
        destinationPlayer.pause()
        let time = destinationPlayer.currentTime()
        return (time.isNumeric ? time.seconds : 0, wasPlaying)
    }

    /// Flies back to fully open and scrubs the player back to the frame the drag started on,
    /// then resumes playback if it was playing.
    private func cancelDrag() {
        withAnimation(.easeInOut(duration: flightDuration)) { progress = 1 }
        guard let origin = dragScrubOrigin, let destinationPlayer else { return }
        dragScrubOrigin = nil
        scrubber.animate(from: currentTime(of: destinationPlayer), to: origin.time, duration: flightDuration)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(flightDuration * 1_000_000_000))
            guard dragScrubOrigin == nil, !isClosing, origin.wasPlaying else { return }
            destinationPlayer.play()
        }
    }

    private func currentTime(of player: AVPlayer) -> TimeInterval {
        let time = player.currentTime()
        return time.isNumeric ? time.seconds : 0
    }

    /// Reverse flight back to the tile — scrubbing the destination's player from the frame it's
    /// showing back to the poster frame the tile shows — then, once it's visually landed, the
    /// actual dismiss. `Transaction.disablesAnimations` alone leaves a residual slide visible:
    /// it suppresses SwiftUI's own animation system but not the UIKit `dismiss(animated:)` call
    /// that backs `fullScreenCover` underneath, so the already-landed card visibly slides
    /// off-screen with the system's own cover-dismiss transition — the same issue
    /// `HomeView.presentSlot` hit on the opening side, fixed there with
    /// `UIView.setAnimationsEnabled(false)`.
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
        isClosing = true
        let origin = beginPresenterScrub()
        dragScrubOrigin = nil
        withAnimation(.easeInOut(duration: flightDuration)) { progress = 0 }
        if destinationPlayer != nil {
            scrubber.animate(from: origin.time, to: 0, duration: flightDuration)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((flightDuration + 0.05) * 1_000_000_000))
            // Never before the scrub's final seek has put the landing frame on screen.
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
