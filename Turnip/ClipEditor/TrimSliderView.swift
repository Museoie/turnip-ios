import Foundation
import SwiftUI

/// The editor's scrub bar: the whole source video's timeline, with drag handles on
/// start/end and a playhead tracking preview playback (`docs/UIUX.md` § "Clip Detail /
/// Editor").
///
/// The timeline spans the whole asset (`ClipEditorViewModel.visibleRange`), not a
/// zoomed-in range around the window — so a tile's position always reads as "roughly
/// this part of the video." That makes the handles sub-pixel-precise on a multi-minute
/// video, so dragging maps vertical drag distance to precision via `ScrubCalculator`
/// (`docs/SCRUB_DESIGN.md`): dragging straight horizontal moves the handle 1:1; dragging
/// upward makes the same horizontal movement move the handle a smaller amount, for fine
/// control; dragging downward is neutral. Dragging anywhere on the timeline grabs the
/// nearer handle, and the drag's time mapping is frozen for the gesture so the draft
/// window's own growth can't shift the scale mid-drag. Handle drags report through the
/// view model, so the crop rect re-derives live.
struct TrimSliderView: View {
    @ObservedObject var viewModel: ClipEditorViewModel
    @GestureState private var drag: TimelineDrag?
    // SwiftUI resets `@GestureState` to nil when the gesture's lifecycle ends, but
    // `DragGesture.onEnded` does not fire on a system-cancelled drag (phone call,
    // Control Center) — so the in-flight drag's presence, not its callbacks, is the
    // reliable signal that a trim interaction is over.

    /// The grabbed handle's own time as of the drag's first touch (after the
    /// grab-anywhere jump below), so `ScrubCalculator` is applied relative to where the
    /// handle stood rather than by accumulating each tick's delta onto the last
    /// (`docs/SCRUB_DESIGN.md` "Gesture State"). `nil` between drags (and defensively
    /// cleared alongside the trim latch — see the `onChange(of: drag != nil)` below).
    @State private var dragStartTime: TimeInterval?
    /// The gesture's cumulative `translation` at the moment `dragStartTime` was captured,
    /// so later ticks can measure movement *since the jump* rather than since the raw
    /// touch-down that produced it — `DragGesture.translation` only ever accumulates from
    /// touch-down.
    @State private var dragStartTranslation: CGSize?

    private enum ActiveHandle {
        case start, end
    }

    /// The in-flight drag: which handle it grabbed plus the frozen time mapping.
    private struct TimelineDrag {
        let handle: ActiveHandle
        let range: ClosedRange<TimeInterval>
        let width: CGFloat
    }

    /// The timeline row's height.
    private static let rowHeight: CGFloat = 56

    var body: some View {
        if let range = viewModel.visibleRange {
            // Frozen for the gesture's duration: the drag's time mapping is captured once in
            // `TimelineDrag`, so the drawing must use that same range — the live range
            // tracks the growing window and would let the handles drift out from under the
            // finger mid-drag.
            let drawRange = drag?.range ?? range
            VStack(spacing: 4) {
                timeline(range: drawRange)
                HStack {
                    Text(ClipDurationFormatter.string(from: viewModel.window.startTime))
                    Spacer()
                    Text(viewModel.durationLabel)
                    Spacer()
                    Text(ClipDurationFormatter.string(from: viewModel.window.endTime))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Trim range \(ClipDurationFormatter.string(from: viewModel.window.startTime)) to "
                        + ClipDurationFormatter.string(from: viewModel.window.endTime))
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Loading timeline")
        }
    }

    private func timeline(range: ClosedRange<TimeInterval>) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(height: 40)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(
                        width: position(of: viewModel.window.endTime, in: range, width: width)
                            - position(of: viewModel.window.startTime, in: range, width: width),
                        height: 40)
                    .offset(x: position(of: viewModel.window.startTime, in: range, width: width))
                Rectangle()
                    .fill(.primary)
                    .frame(width: 2, height: 52)
                    .offset(x: position(of: viewModel.playbackTime, in: range, width: width) - 1)
                handle(
                    at: viewModel.window.startTime, in: range, width: width,
                    label: "Trim start",
                    trim: { viewModel.trimStart(to: $0) })
                handle(
                    at: viewModel.window.endTime, in: range, width: width,
                    label: "Trim end",
                    trim: { viewModel.trimEnd(to: $0) })
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
            .gesture(timelineGesture(range: range, viewportSize: proxy.size))
        }
        .frame(height: Self.rowHeight)
        .onChange(of: drag != nil) { isDragging in
            // `onEnded` never fires when the system cancels the drag (call, Control
            // Center); the GestureState reset above is the only signal in that case.
            // If the trim latch is still set, `finishTrim()` never ran, so the player
            // would stay paused and `tick` would suppress the loop-back for the rest
            // of the session. The call is idempotent (clear + seek + play), so this
            // can't fight the normal `onEnded` path — whichever fires first wins.
            if !isDragging {
                dragStartTime = nil
                dragStartTranslation = nil
                if viewModel.isTrimming {
                    viewModel.finishTrim()
                }
            }
        }
    }

    /// The timeline's drag interaction, extracted from `timeline(range:)` so the view
    /// builder stays within the function-body length limit.
    ///
    /// The very first update of a drag jumps the grabbed handle straight to the touch
    /// (grab-anywhere-on-the-timeline). Every update after that re-derives the handle's
    /// time from `ScrubCalculator`, applied to the movement since that jump.
    private func timelineGesture(range: ClosedRange<TimeInterval>, viewportSize: CGSize) -> some Gesture {
        let width = viewportSize.width
        return DragGesture()
            .updating($drag) { value, state, _ in
                if state == nil {
                    let touched = self.time(at: value.location.x, in: range, width: width)
                    state = TimelineDrag(
                        handle: nearestHandle(to: touched), range: range, width: width)
                }
            }
            .onChanged { value in
                guard let drag else { return }
                guard let dragStartTime else {
                    // First sample of this drag: grab-anywhere jumps straight to the
                    // touch; ScrubCalculator governs movement after this, relative to
                    // the handle's resulting (possibly clamped) time.
                    let touched = self.time(at: value.location.x, in: drag.range, width: drag.width)
                    apply(touched, to: drag.handle)
                    dragStartTime = drag.handle == .start ? viewModel.window.startTime : viewModel.window.endTime
                    dragStartTranslation = value.translation
                    return
                }
                let origin = dragStartTranslation ?? .zero
                let translationSinceJump = CGSize(
                    width: value.translation.width - origin.width,
                    height: value.translation.height - origin.height)
                let result = ScrubCalculator.calculate(
                    translation: translationSinceJump, viewportSize: viewportSize)
                let rangeSpan = drag.range.upperBound - drag.range.lowerBound
                let newTime = dragStartTime + result.timelineDelta / 2 * rangeSpan
                apply(newTime, to: drag.handle)
            }
            .onEnded { _ in
                dragStartTime = nil
                dragStartTranslation = nil
                viewModel.finishTrim()
            }
    }

    private func apply(_ time: TimeInterval, to handle: ActiveHandle) {
        switch handle {
        case .start: viewModel.trimStart(to: time)
        case .end: viewModel.trimEnd(to: time)
        }
    }

    /// The handle nearer to a touch, so a drag anywhere on the timeline grabs something
    /// sensible instead of requiring a hit on the 12pt handle.
    private func nearestHandle(to time: TimeInterval) -> ActiveHandle {
        let window = viewModel.window
        return abs(time - window.startTime) <= abs(time - window.endTime) ? .start : .end
    }

    private func handle(
        at time: TimeInterval,
        in range: ClosedRange<TimeInterval>,
        width: CGFloat,
        label: String,
        trim: @escaping (TimeInterval) -> Void
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor)
                .frame(width: 12, height: 48)
        }
        .frame(width: 32, height: 56)
        .contentShape(Rectangle())
        .offset(x: position(of: time, in: range, width: width) - 16)
        .accessibilityLabel(label)
        .accessibilityValue(ClipDurationFormatter.string(from: time))
        .accessibilityAdjustableAction { direction in
            // Tenth-second steps for VoiceOver.
            trim(time + (direction == .increment ? 0.1 : -0.1))
            viewModel.finishTrim()
        }
    }

    private func position(
        of time: TimeInterval, in range: ClosedRange<TimeInterval>, width: CGFloat
    ) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0, width > 0 else { return 0 }
        return CGFloat((time - range.lowerBound) / span) * width
    }

    private func time(
        at x: CGFloat, in range: ClosedRange<TimeInterval>, width: CGFloat
    ) -> TimeInterval {
        let span = range.upperBound - range.lowerBound
        guard width > 0 else { return range.lowerBound }
        return range.lowerBound + TimeInterval(x / width) * span
    }
}
