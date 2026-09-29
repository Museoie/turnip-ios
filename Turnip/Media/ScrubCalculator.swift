import CoreGraphics
import Foundation

/// The geometry behind every scrub-bar drag: horizontal movement scrubs the timeline
/// directly, and dragging upward reduces horizontal sensitivity for finer control: farther
/// up, finer. Downward movement is neutral. Kept out of the view so the model is exercised
/// without a running gesture (`docs/SCRUB_DESIGN.md`, `docs/SCRUB_DEMO.html`).
enum ScrubCalculator {
    /// One screen-width of horizontal drag, with no vertical component, scrubs half the
    /// timeline (`timelineDelta == 1`) — so a `-maximumTimelineDelta...maximumTimelineDelta`
    /// drag range covers the whole timeline twice over, once each direction.
    private static let maximumTimelineDelta = 2.0

    /// Signed normalized timeline displacement.
    ///
    /// -2 = one full duration backward, 0 = no movement, +2 = one full duration forward.
    struct Result {
        let timelineDelta: Double
    }

    /// `translation` and `viewportSize` are raw screen-space values (e.g. a `DragGesture`'s
    /// `.translation` and the gesture's own view size) — all normalization happens here.
    ///
    /// Normalized against *half* the viewport width, not the full width: a single
    /// edge-to-edge drag across the viewport is meant to scrub the whole timeline
    /// (`x` reaching `2`), not half of it (`docs/SCRUB_DEMO.html`).
    static func calculate(translation: CGSize, viewportSize: CGSize) -> Result {
        guard viewportSize.width > 0 else { return Result(timelineDelta: 0) }

        let unit = Double(viewportSize.width) / 2
        let x = Double(translation.width) / unit
        let y = Double(-translation.height) / unit

        let direction: Double = x < 0 ? -1 : 1
        let magnitude = calculateNormalized(horizontal: abs(x), vertical: max(y, 0))

        let signed = direction * magnitude
        return Result(timelineDelta: min(max(signed, -maximumTimelineDelta), maximumTimelineDelta))
    }

    /// The normalized solver, kept separate from coordinate normalization so the
    /// mathematical model is directly testable (`docs/SCRUB_DESIGN.md` "Mathematical Model").
    ///
    /// For `x > 2`, this has an intentional discontinuity: at `y == 0`, `t == x`, but as `y`
    /// grows past zero `t` drops toward `2`. That's the smaller root of the two the model's
    /// quadratic admits — the larger root would make upward dragging *increase* `t`, which is
    /// the opposite of the intended precision behavior.
    static func calculateNormalized(horizontal x: Double, vertical y: Double) -> Double {
        guard y > 0 else { return x }

        let b = x + y + 2
        let discriminant = max(0, b * b - 8 * x)
        return max(0, (b - discriminant.squareRoot()) / 2)
    }
}
