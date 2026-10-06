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
/// `onRequestSlideClose` is the clip list's back action: a sideways pop rather than a flight
/// back into the tile, see `HomeExpansionContainer.slideClose()`.
struct HomeExpansionCloseHandlers {
    let onRequestClose: () -> Void
    let onRequestSlideClose: () -> Void
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
    /// Called the instant the opening flight starts moving — which is when the presenter
    /// should hide the tile underneath. Not when the cover is requested: UIKit takes a few
    /// frames to present it, and a tile hidden before the card exists leaves its slot empty
    /// in the grid for those frames.
    var onFlightStarted: () -> Void = {}
    /// Called as `slideClose()` starts moving the page sideways, so the presenter can show
    /// the hidden tile again: the grid is uncovered as the page slides off it.
    var onSlideOutStarted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var progress: CGFloat = 0
    /// The destination chrome's opacity and the scrim's over the grid: `0` at the tile, `1`
    /// fully open. Neither is derived from `progress`, even though a drag writes the same
    /// value to all three, because each animates on its own curve: the flight eases in and
    /// out, while a fade eases in for what appears and out for what disappears
    /// (`ExpansionFlightGeometry.crossfadeAnimation`) — which on any one flight is the chrome
    /// for one and the grid under the scrim for the other, so they can't share a value
    /// either. A value computed from `progress` could only ever follow the flight's curve.
    @State private var chromeOpacity: CGFloat = 0
    @State private var scrimOpacity: CGFloat = 0
    /// `slideClose()`'s own clock, separate from `progress` (which stays at `1` — the
    /// destination is fully open while it leaves): `0` in place, `1` a full screen width
    /// off to the trailing edge.
    @State private var slideProgress: CGFloat = 0
    /// Whether the card has landed on the destination: `true` from the opening flight's
    /// completion until the first frame of any close. Drives the hard cut between the card
    /// and the destination's video surface — both read it, and it's written with animations
    /// disabled (`setLanded`), so the swap is one atomic, unanimated frame. Also handed to the
    /// destination as `expansionHasLanded`; see that environment value for why it's a flag
    /// rather than the live `progress`.
    @State private var hasLanded = false
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
    private let flightDuration = ExpansionFlightGeometry.flightDuration
    /// How long `slideClose()` takes to carry the page off screen — a navigation pop's pace,
    /// not the flight's.
    private let slideDuration: TimeInterval = 0.3
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
            let chromeCrossfades = ExpansionFlightGeometry.destinationChromeCrossfades

            ZStack {
                Color.black
                    .opacity(scrimOpacity)
                    .ignoresSafeArea()

                if !chromeCrossfades {
                    // Under the card, hidden for the whole flight and cut in once the card
                    // has landed: the pre-iOS 18 fallback, where the destination's navigation
                    // container can't be made see-through (see `destinationChromeCrossfades`).
                    destinationContent()
                        .opacity(hasLanded ? 1 : 0)
                }

                cardLayer(destination: destination, focus: focus)
                    // The hard cut to the destination's video surface — unanimated, since
                    // `hasLanded` is only ever written with animations disabled.
                    .opacity(hasLanded ? 0 : 1)
                    .clipShape(ExpansionFlightClip(
                        progress: progress, sourceFrame: source, destination: destination,
                        focus: focus, sourceCornerRadius: sourceCornerRadius))
                    .modifier(ExpansionFlightEffect(
                        progress: progress, sourceFrame: source, destination: destination, focus: focus))
                    .allowsHitTesting(!hasLanded)

                if chromeCrossfades {
                    // Over the card, fading in with the flight: its chrome (controls, the
                    // scrub bar, its own chevron) cross-fades in place over the growing
                    // picture, while its backdrop and video surface stay hidden under
                    // `expansionVideoSurface()` until the card has landed — the card draws
                    // those in their place. A plain `.opacity`, not a cut: it's meant to
                    // interpolate across the whole flight, which `.opacity` does on its own.
                    destinationContent()
                        .opacity(chromeOpacity)
                }
            }
            .offset(x: slideProgress * screen.size.width)
        }
        .ignoresSafeArea()
        .onAppear {
            onFlightStarted()
            ExpansionFlightGeometry.animateFlight({ progress = 1 }, completion: {
                guard !isClosing, dragScrubOrigin == nil else { return }
                setLanded(true)
            })
            animateCrossfade(open: true)
        }
    }

    /// The destination, with `hasLanded` handed down for its video-surface cut and its
    /// measurements handed back up. Built by one of the two branches in `body`.
    private func destinationContent() -> some View {
        content(closeHandlers)
            .environment(\.expansionHasLanded, hasLanded)
            .allowsHitTesting(hasLanded)
            .onPreferenceChange(ProcessingVideoFramePreferenceKey.self) { frame in
                guard frame != .zero else { return }
                measuredDestination = frame
            }
            .onPreferenceChange(ProcessingPlayerPreferenceKey.self) { handle in
                destinationPlayer = handle.player
                scrubber.seek = handle.player.map(FlightScrubber.exactSeek) ?? { _ in }
            }
    }

    private var closeHandlers: HomeExpansionCloseHandlers {
        HomeExpansionCloseHandlers(
            onRequestClose: close,
            onRequestSlideClose: slideClose,
            dismissTranslationChanged: { translation in
                setLanded(false)
                let travel = max(0, translation)
                progress = 1 - min(travel / dismissTravel, 1)
                // Under the finger all three follow the drag 1:1; the curves only differ
                // when they animate on their own.
                chromeOpacity = progress
                scrimOpacity = progress
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

    /// Fades the chrome and the scrim toward fully open or back toward the tile, each on the
    /// curve for its own direction: toward open the destination's chrome appears while the
    /// grid under the scrim disappears; back toward the tile, the reverse. Not called under a
    /// drag, which writes both 1:1 from the finger instead.
    private func animateCrossfade(open: Bool) {
        let target: CGFloat = open ? 1 : 0
        withAnimation(ExpansionFlightGeometry.crossfadeAnimation(appearing: open)) { chromeOpacity = target }
        withAnimation(ExpansionFlightGeometry.crossfadeAnimation(appearing: !open)) { scrimOpacity = target }
    }

    /// Writes `hasLanded` with animations disabled, so the card/destination swap it drives
    /// is an instant cut even when it lands in the same update as an animated `progress`
    /// change (a close's first frame).
    private func setLanded(_ landed: Bool) {
        guard hasLanded != landed else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { hasLanded = landed }
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
        // Cleared before anything can return early below (a destination without a player
        // has an origin but nothing to scrub), since the completion reads it to tell this
        // drag's snap-back from a newer drag's.
        let origin = dragScrubOrigin
        dragScrubOrigin = nil
        if progress < 1 {
            ExpansionFlightGeometry.animateFlight({ progress = 1 }, completion: {
                // Not if another drag has started, or a close, while this snap-back ran.
                guard dragScrubOrigin == nil, !isClosing else { return }
                setLanded(true)
            })
            animateCrossfade(open: true)
        } else {
            // The drag never moved the card (it only ever went up), so there is nothing to
            // animate and no completion to wait for.
            setLanded(true)
        }
        guard let origin, let destinationPlayer else { return }
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
        setLanded(false)
        let origin = beginPresenterScrub()
        dragScrubOrigin = nil
        withAnimation(.easeInOut(duration: flightDuration)) { progress = 0 }
        animateCrossfade(open: false)
        if destinationPlayer != nil {
            scrubber.animate(from: origin.time, to: 0, duration: flightDuration)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((flightDuration + 0.05) * 1_000_000_000))
            // Never before the scrub's final seek has put the landing frame on screen.
            await scrubber.waitUntilDone()
            dismissSuppressingSystemTransition()
        }
    }

    /// The clip list's way out: the page slides off to the trailing edge like a navigation
    /// pop, uncovering Home, instead of flying back into the tile. The list's tiles are the
    /// clips cut out of the video, not the video itself, so a shrink back into the video's
    /// tile reads as the wrong thing returning. `progress` stays at `1` throughout — the
    /// destination is fully open while it leaves — and `onSlideOutStarted` reveals the tile
    /// underneath as the grid comes back into view.
    private func slideClose() {
        guard !isClosing else { return }
        isClosing = true
        scrubber.cancel()
        onSlideOutStarted()
        withAnimation(.easeInOut(duration: slideDuration)) { slideProgress = 1 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((slideDuration + 0.05) * 1_000_000_000))
            dismissSuppressingSystemTransition()
        }
    }

    /// The actual dismiss, once a close has visually landed — see `close()`'s doc comment for
    /// why both suppressions, and the 0.5s hold, are needed.
    private func dismissSuppressingSystemTransition() {
        UIView.setAnimationsEnabled(false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dismiss() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UIView.setAnimationsEnabled(true)
        }
    }
}
