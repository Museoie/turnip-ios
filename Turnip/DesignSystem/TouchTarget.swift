import SwiftUI

extension View {
    /// Grows the region a finger has to find out to the 44 pt floor
    /// (`docs/ACCESSIBILITY.md`), without changing what the view lays out.
    ///
    /// An inset rather than a `frame`: a frame re-centers the drawn glyph inside the larger box
    /// and moves it — off a tile's corner, or by stretching the pill around it — while the whole
    /// point here is to leave the drawing where it is. Applied to a button's label rather than
    /// to the button, so it becomes part of that button's own hit-testing region, the same
    /// placement `ScrimIconButton` uses for its frame.
    ///
    /// On iOS 17 and later this also moves VoiceOver's focus rectangle, which is drawn from the
    /// accessibility content shape. That shape kind is iOS 17+ while the deployment floor is
    /// 16.0 (`project.yml`), so below 17 the interaction shape widens alone: the control is
    /// still reachable and still hit-testable at 44 pt, and only the focus rectangle stays
    /// drawn tight to the glyph.
    ///
    /// `axes` limits the growth for a control laid out beside another one, where widening it
    /// sideways would take taps meant for its neighbor.
    @ViewBuilder
    func touchTarget(insetBy inset: CGFloat, axes: Axis.Set = [.horizontal, .vertical]) -> some View {
        let shape = OutsetRectangle(
            dx: axes.contains(.horizontal) ? inset : 0,
            dy: axes.contains(.vertical) ? inset : 0)
        if #available(iOS 17.0, *) {
            contentShape([.interaction, .accessibility], shape)
        } else {
            contentShape(shape)
        }
    }
}

/// A rectangle grown past its frame by `dx` on each side and `dy` above and below.
private struct OutsetRectangle: Shape {
    let dx: CGFloat
    let dy: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -dx, dy: -dy))
    }
}
