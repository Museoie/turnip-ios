import SwiftUI

/// Lays chips out in rows, left to right, wrapping to a new row when the next one wouldn't fit.
/// Wrapping rather than scrolling sideways: Name Clips' pager owns every horizontal drag.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A capsule chip: filled for a name a clip has, outlined for a suggestion.
struct ChipButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(isProminent ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .background {
                if isProminent {
                    Capsule().fill(Color.accentColor)
                } else {
                    Capsule().strokeBorder(Color.secondary.opacity(0.6))
                }
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
            // Up to the 44 pt floor vertically; sideways the next chip is only 8 pt away.
            .touchTarget(insetBy: 5, axes: .vertical)
    }
}

/// Title first, icon after: a chip's remove mark sits at its end.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.font(.caption.weight(.bold))
        }
    }
}

/// The full-screen spinner a save to Photos runs under, on Clip List and on Name Clips.
struct SavingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            ProgressView {
                Text("Saving to Photos…")
            }
            .tint(.white)
            .foregroundStyle(.white)
        }
    }
}
