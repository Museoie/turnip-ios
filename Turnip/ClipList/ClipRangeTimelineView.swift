import SwiftUI

/// A read-only indicator of where a clip's window sits within the full source video
/// (`docs/UIUX.md` § "Clip List (triage)"). The track spans the whole asset
/// (`0...duration`), not just the window plus local context, with the window drawn as
/// a highlighted segment — so a glance at the grid shows roughly which part of the
/// video each clip is from.
///
/// Not draggable: trimming lives in the editor (a tile tap opens it), so the
/// timeline in the grid can show the whole video instead of a zoomed-in range
/// that stays finger-sized.
struct ClipRangeTimelineView: View {
    let window: TrickWindow
    let duration: TimeInterval

    private static let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = max(duration, 0.01)
            let startX = position(of: window.startTime, span: span, width: width)
            let endX = position(of: window.endTime, span: span, width: width)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule()
                    .fill(.white)
                    .frame(width: max(endX - startX, 2))
                    .offset(x: startX)
            }
        }
        .frame(height: Self.trackHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Clip from \(ClipDurationFormatter.string(from: window.startTime)) to "
                + ClipDurationFormatter.string(from: window.endTime)
                + " of \(ClipDurationFormatter.string(from: duration))")
    }

    private func position(of time: TimeInterval, span: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat(min(max(time / span, 0), 1)) * width
    }
}
