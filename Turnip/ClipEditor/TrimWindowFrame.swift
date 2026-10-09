import SwiftUI

/// The trim window's frame on the editor's timeline (`docs/UIUX.md` § "Clip Detail /
/// Editor"): a rounded band around the clip's span with a thick cap at each end for the
/// handle, open in the middle so the track shows through. Drawn as a path rather than
/// a stretched image so it tints with the accent color, scales with the window
/// continuously, and stays crisp at any display scale.
///
/// Filled with `FillStyle(eoFill: true)`: the inner rounded rect is a second subpath,
/// and even-odd filling leaves it empty.
struct TrimWindowFrameShape: Shape {
    /// The width of each end cap. The caps sit outside the clip's own span, so the
    /// timeline's usable width is the track minus one cap at either end.
    static let capWidth: CGFloat = 15
    /// The thickness of the top and bottom bars.
    static let barThickness: CGFloat = 5
    static let outerCornerRadius: CGFloat = 8
    static let innerCornerRadius: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: Self.outerCornerRadius)
        let inner = rect.insetBy(dx: Self.capWidth, dy: Self.barThickness)
        if inner.width > 0, inner.height > 0 {
            path.addPath(Path(roundedRect: inner, cornerRadius: Self.innerCornerRadius))
        }
        return path
    }
}

/// The glyph inside a handle cap: a filled triangle whose tip points away from the
/// clip, so each cap reads as "pull this way to widen."
struct TrimHandleGlyphShape: Shape {
    enum Direction {
        case leading, trailing
    }

    let direction: Direction

    func path(in rect: CGRect) -> Path {
        let tipX = direction == .leading ? rect.minX : rect.maxX
        let baseX = direction == .leading ? rect.maxX : rect.minX
        var path = Path()
        path.move(to: CGPoint(x: baseX, y: rect.minY))
        path.addLine(to: CGPoint(x: tipX, y: rect.midY))
        path.addLine(to: CGPoint(x: baseX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A handle cap's glyph, sized to the cap. The triangle's corners are softened by
/// stroking its outline with round joins in the same color as its fill.
struct TrimHandleGlyphView: View {
    let direction: TrimHandleGlyphShape.Direction

    private static let size = CGSize(width: 5, height: 17)
    private static let cornerSoftening: CGFloat = 2

    var body: some View {
        let shape = TrimHandleGlyphShape(direction: direction)
        shape
            .fill(.white)
            .overlay(
                shape.stroke(
                    .white,
                    style: StrokeStyle(lineWidth: Self.cornerSoftening, lineJoin: .round)))
            .frame(width: Self.size.width, height: Self.size.height)
            .padding(Self.cornerSoftening / 2)
    }
}

/// The playhead: a white pill taller than the window frame, drawn over it, so the
/// current frame stays readable while it crosses the frame's bars.
struct TrimPlayheadView: View {
    static let size = CGSize(width: 8, height: 56)

    var body: some View {
        Capsule()
            .fill(.white)
            .overlay(Capsule().strokeBorder(Color(white: 0.5), lineWidth: 0.5))
            .frame(width: Self.size.width, height: Self.size.height)
    }
}
