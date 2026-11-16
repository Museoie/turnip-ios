import SwiftUI

/// Lays chips out on one line, left to right, and never wraps: each at its own width while the
/// line has room for it, the first that doesn't fit cut short to the room left, and the chips
/// after it left out. A chip is cut by being offered less width than it wants, so it has to cut
/// its own text, as a one-line `Text` does with an ellipsis at its tail.
///
/// A left-out chip is placed just past the line's trailing edge: clip the line (`.clipped()`) so
/// it doesn't show.
struct ChipLine: Layout {
    var spacing: CGFloat = 4
    /// The least width a chip is cut to: its padding, a letter and the ellipsis. With less room
    /// left than that, the chip before it is cut instead, so the line still ends in an ellipsis.
    var minimumCutWidth: CGFloat = 28

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        // Every chip whole, or the width offered when that is less.
        let ideal = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: min(proposal.width ?? ideal, ideal), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = Self.widths(
            ideal: sizes.map(\.width), spacing: spacing, available: bounds.width, minimumCutWidth: minimumCutWidth)
        var x = bounds.minX
        for (index, width) in widths.enumerated() {
            guard let width else {
                subviews[index].place(
                    at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topLeading, proposal: .zero)
                continue
            }
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: sizes[index].height))
            x += width + spacing
        }
    }

    /// The width each chip, `ideal` wide on its own, is offered on a line `available` wide; `nil`
    /// for one left out. Every chip that fits keeps its own width. The first that doesn't is
    /// offered the room left when that is at least `minimumCutWidth`; otherwise it is left out
    /// and the chip before it is offered a point less than its own width, which cuts it. The
    /// first chip, with nothing before it, is offered whatever room there is.
    static func widths(
        ideal: [CGFloat], spacing: CGFloat, available: CGFloat, minimumCutWidth: CGFloat
    ) -> [CGFloat?] {
        var placed: [CGFloat] = []
        var end: CGFloat = 0
        for width in ideal {
            let start = placed.isEmpty ? 0 : end + spacing
            if start + width <= available + 0.5 {
                placed.append(width)
                end = start + width
                continue
            }
            let room = available - start
            if room >= minimumCutWidth || placed.isEmpty {
                placed.append(max(room, 0))
            } else {
                placed[placed.count - 1] = max(placed[placed.count - 1] - 1, 0)
            }
            break
        }
        return placed.map { Optional($0) } + Array(repeating: nil, count: ideal.count - placed.count)
    }
}
