import AVFoundation
import SwiftUI

/// The per-frame geometry of a Photos-style expansion flight, shared by
/// `ClipExpansionContainer` and `HomeExpansionContainer`: where the flying card is on
/// screen (`rect`), which part of its full-size content is visible (`region`), and the
/// one uniform scale mapping the two.
///
/// The card is laid out once, at the destination's size and position, and never changes
/// size during a flight. What changes is a window onto its content: `region`, in the
/// card's own coordinates, grows from the part of the content the source tile showed
/// to the whole content, and is drawn scaled by a single factor onto `rect`. Width and
/// height always scale together, so the content is cropped as it grows and never
/// stretched — the tile's center-cropped picture "uncrops" into the destination's full
/// picture, the way the real Photos app's zoom does. The container applies this through
/// `ExpansionFlightClip` (the window) and `ExpansionFlightEffect` (the scale and
/// placement), both render-time primitives driven by the same live `progress`.
struct ExpansionFlightGeometry: Equatable {
    /// Where the card is on screen, in the same space `sourceFrame`/`destination` use.
    let rect: CGRect
    /// The visible window onto the card's content, in the card's own coordinates
    /// (origin at `destination`'s top-left).
    let region: CGRect
    /// The uniform scale mapping `region` onto `rect`.
    let scale: CGFloat

    /// - Parameters:
    ///   - progress: `0` exactly at the source tile, `1` fully open.
    ///   - sourceFrame: the tile's on-screen frame.
    ///   - destination: the settled content's on-screen frame; the card is laid out here.
    ///   - focus: the part of the card's content the tile shows, in the card's own
    ///     coordinates. The tile aspect-fills it, so the window at `progress == 0` is
    ///     its largest sub-rect with the tile's own aspect ratio, centered.
    static func resolve(
        progress: CGFloat, sourceFrame: CGRect, destination: CGRect, focus: CGRect
    ) -> ExpansionFlightGeometry {
        let width = sourceFrame.width + (destination.width - sourceFrame.width) * progress
        let height = sourceFrame.height + (destination.height - sourceFrame.height) * progress
        let midX = sourceFrame.midX + (destination.midX - sourceFrame.midX) * progress
        let midY = sourceFrame.midY + (destination.midY - sourceFrame.midY) * progress
        let rect = CGRect(x: midX - width / 2, y: midY - height / 2, width: width, height: height)

        let focusRect = focus.width > 0 && focus.height > 0
            ? focus
            : CGRect(origin: .zero, size: destination.size)
        let sourceScale = max(
            sourceFrame.width / max(focusRect.width, 1),
            sourceFrame.height / max(focusRect.height, 1))
        let scale = sourceScale + (1 - sourceScale) * progress
        let regionMidX = focusRect.midX + (destination.width / 2 - focusRect.midX) * progress
        let regionMidY = focusRect.midY + (destination.height / 2 - focusRect.midY) * progress
        let regionWidth = width / max(scale, 0.0001)
        let regionHeight = height / max(scale, 0.0001)
        let region = CGRect(
            x: regionMidX - regionWidth / 2, y: regionMidY - regionHeight / 2,
            width: regionWidth, height: regionHeight)
        return ExpansionFlightGeometry(rect: rect, region: region, scale: scale)
    }
}

/// The window onto the flying card's content, as an animatable clip: a rounded
/// rectangle at `ExpansionFlightGeometry.region`, in the coordinates of the card's
/// post-`.position` layer (whose origin is the screen's). The corner radius eases from
/// the tile's to 0, expressed in content space so it reads as the tile's radius on
/// screen after `ExpansionFlightEffect`'s scale.
///
/// `Shape` is rendered, not laid out, so animating it never feeds back into layout
/// the way an animated `.frame`/`.position` does. It must sit outside
/// `ExpansionCrossfadeCut`, whose animation-suppressing transaction would otherwise
/// snap it to its target.
struct ExpansionFlightClip: Shape {
    var progress: CGFloat
    let sourceFrame: CGRect
    let destination: CGRect
    let focus: CGRect
    let sourceCornerRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let geometry = ExpansionFlightGeometry.resolve(
            progress: progress, sourceFrame: sourceFrame, destination: destination, focus: focus)
        let window = geometry.region.offsetBy(dx: destination.minX, dy: destination.minY)
        let radius = sourceCornerRadius * (1 - progress) / max(geometry.scale, 0.0001)
        return Path(roundedRect: window, cornerRadius: radius)
    }
}

/// Flies the card — laid out at `destination`, fixed — to `ExpansionFlightGeometry.rect`
/// as a render-time `ProjectionTransform`: the clipped window at `region` is scaled
/// uniformly and placed over `rect`. Applied to the card's post-`.position` layer,
/// whose origin is the screen's, so the transform maps the layer's own coordinates
/// (screen space) directly.
///
/// A `GeometryEffect` rather than animated layout modifiers: `effectValue(size:)` runs
/// after layout against an already-settled size and returns a transform for rendering,
/// so a per-frame change can't trigger another layout pass. Must sit outside
/// `ExpansionCrossfadeCut` for the same reason `ExpansionFlightClip` must.
struct ExpansionFlightEffect: GeometryEffect {
    var progress: CGFloat
    let sourceFrame: CGRect
    let destination: CGRect
    let focus: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let geometry = ExpansionFlightGeometry.resolve(
            progress: progress, sourceFrame: sourceFrame, destination: destination, focus: focus)
        let scale = geometry.scale
        let offsetX = geometry.rect.minX - scale * (destination.minX + geometry.region.minX)
        let offsetY = geometry.rect.minY - scale * (destination.minY + geometry.region.minY)
        return ProjectionTransform(
            CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY))
    }
}

/// An instant visibility cut at `threshold`, evaluated against the *live* animated
/// `progress` rather than its target value.
///
/// A plain `View.body` getter runs once per `withAnimation`-driven `progress` change, at
/// the target value, so a threshold test there only ever sees the two endpoints — and
/// since `.opacity` is itself animatable, SwiftUI then interpolates between those two
/// opacities across the whole flight, producing a cross-dissolve. Conforming to
/// `Animatable` makes SwiftUI call `body(content:)` once per rendered frame with the
/// interpolated `progress`, so the cut fires partway through the flight. The
/// `.transaction { $0.animation = nil }` keeps that per-frame jump from being smoothed
/// again — and also suppresses every animation in the modified subtree, which is why
/// anything that must animate goes outside this modifier, never inside it.
struct ExpansionCrossfadeCut: Animatable, ViewModifier {
    var progress: CGFloat
    let threshold: CGFloat
    /// `true` for the real destination content (visible at/above `threshold`), `false`
    /// for the card (visible below it) — the two are never both `true` at once.
    let visibleAboveThreshold: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let isVisible = visibleAboveThreshold ? progress >= threshold : progress < threshold
        content
            .opacity(isVisible ? 1 : 0)
            .transaction { $0.animation = nil }
    }
}

/// Scrubs a player's displayed frame alongside an expansion flight, so the card's video
/// plays back (or forward) from the frame it starts on to the frame it lands on while
/// it grows or shrinks.
///
/// Seeks are chained, one in flight at a time: each one is awaited before the next
/// target is computed from the clock, so a slow decode just lowers the scrub's frame
/// rate rather than queueing seeks the player will discard. An animated scrub always
/// ends with an exact seek to its final time, so the landing frame doesn't depend on
/// how many intermediate seeks completed. `request(_:)` serves an interactive drag the
/// same way, keeping only the latest target while a seek is still in flight.
@MainActor
final class FlightScrubber: ObservableObject {
    /// Performs one exact seek and returns once the player has that frame. Settable, for
    /// a container whose player only becomes known after it's mounted.
    var seek: (TimeInterval) async -> Void
    private var animationTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var pendingTime: TimeInterval?

    init(seek: @escaping (TimeInterval) async -> Void = { _ in }) {
        self.seek = seek
    }

    /// A seek that drives `player` directly, for a destination that exposes its player
    /// rather than a view model.
    static func exactSeek(on player: AVPlayer) -> (TimeInterval) async -> Void {
        { time in
            let target = CMTime(seconds: time, preferredTimescale: 600)
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Scrubs from `startTime` to `endTime` over `duration`, on the same ease-in-out curve the
    /// flight's own geometry follows. Intermediate seeks stop once another one couldn't
    /// complete before `duration` elapses (judged by how long the previous one took), so
    /// the final exact seek lands as the flight does rather than one decode later.
    func animate(from startTime: TimeInterval, to endTime: TimeInterval, duration: TimeInterval) {
        cancel()
        let start = Date()
        animationTask = Task { [seek] in
            var lastSeekDuration: TimeInterval = 0
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                guard elapsed + lastSeekDuration < duration else { break }
                let fraction = min(1, max(0, elapsed / max(duration, 0.001)))
                let seekStart = Date()
                await seek(startTime + (endTime - startTime) * Self.easeInOut(fraction))
                lastSeekDuration = Date().timeIntervalSince(seekStart)
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            guard !Task.isCancelled else { return }
            await seek(endTime)
        }
    }

    /// Seeks to `time` as soon as the seek in flight, if any, completes — later requests
    /// replace earlier ones that haven't started yet.
    func request(_ time: TimeInterval) {
        pendingTime = time
        guard drainTask == nil else { return }
        drainTask = Task { [seek] in
            while !Task.isCancelled, let next = pendingTime {
                pendingTime = nil
                await seek(next)
            }
            drainTask = nil
        }
    }

    /// Returns once the scrub in progress, if any, has issued its final seek and that
    /// seek has completed — so a presenter can dismiss on the landing frame, not before it.
    func waitUntilDone() async {
        await animationTask?.value
        await drainTask?.value
    }

    func cancel() {
        animationTask?.cancel()
        animationTask = nil
        drainTask?.cancel()
        drainTask = nil
        pendingTime = nil
    }

    /// SwiftUI's `.easeInOut` is a cubic Bézier; this quadratic ease-in-out tracks it
    /// closely enough that the scrub and the geometry read as one motion.
    nonisolated static func easeInOut(_ fraction: Double) -> Double {
        fraction < 0.5
            ? 2 * fraction * fraction
            : 1 - pow(-2 * fraction + 2, 2) / 2
    }
}
