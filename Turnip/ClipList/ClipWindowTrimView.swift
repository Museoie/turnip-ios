import SwiftUI

/// The clip list's inline trim timeline: the asset timeline around one clip's window,
/// with drag handles on start/end (`docs/UIUX.md` § "Clip List (triage)").
///
/// A standalone sibling of the editor's `TrimSliderView`, not a reuse: the editor's
/// slider is wired to its view model (pause-and-seek preview, live crop re-derivation),
/// while this one edits a bare `Binding<TrickWindow>` in place — trims write straight
/// back into the list via `ClipListViewModel.setWindow`. The visual language matches
/// (track, highlighted range, two handles, start/end time labels), and so does the
/// scale: the timeline spans the window plus context, not the whole asset, so the
/// handles stay finger-sized on a multi-minute video. The drag's time mapping is frozen
/// for the gesture so the window's own growth can't shift the scale mid-drag.
struct ClipWindowTrimView: View {
    @Binding var window: TrickWindow
    let duration: TimeInterval

    @GestureState private var drag: TimelineDrag?

    private enum ActiveHandle {
        case start, end
    }

    /// The in-flight drag: which handle it grabbed plus the frozen time mapping.
    private struct TimelineDrag {
        let handle: ActiveHandle
        let range: ClosedRange<TimeInterval>
        let width: CGFloat
    }

    var body: some View {
        // Frozen for the gesture's duration (the same reason as in `TrimSliderView`):
        // the drag's time mapping is captured once in `TimelineDrag`, so the drawing
        // must use that same range — the live range tracks the growing window and would
        // let the handles drift out from under the finger mid-drag.
        let drawRange = drag?.range ?? visibleRange
        VStack(spacing: 4) {
            timeline(range: drawRange)
            HStack {
                Text(ClipDurationFormatter.string(from: window.startTime))
                Spacer()
                Text(ClipDurationFormatter.string(from: window.endTime - window.startTime))
                Spacer()
                Text(ClipDurationFormatter.string(from: window.endTime))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Trim range \(ClipDurationFormatter.string(from: window.startTime)) to "
                    + ClipDurationFormatter.string(from: window.endTime))
        }
    }

    /// The window plus context on both sides, clamped to the asset — the editor's
    /// `visibleRange` rule. The card only renders this view once a positive duration
    /// has loaded, so the fallback range is unreachable in practice; it keeps the
    /// geometry helpers total anyway.
    private var visibleRange: ClosedRange<TimeInterval> {
        let padding = max(window.endTime - window.startTime, 2.0)
        let lower = max(window.startTime - padding, 0)
        let upper = min(window.endTime + padding, duration)
        guard lower < upper else { return 0...max(duration, 1) }
        return lower...upper
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
                        width: position(of: window.endTime, in: range, width: width)
                            - position(of: window.startTime, in: range, width: width),
                        height: 40)
                    .offset(x: position(of: window.startTime, in: range, width: width))
                handle(
                    at: window.startTime, in: range, width: width,
                    label: "Trim start",
                    trim: { trimStart(to: $0) })
                handle(
                    at: window.endTime, in: range, width: width,
                    label: "Trim end",
                    trim: { trimEnd(to: $0) })
            }
            .frame(height: 56)
            .contentShape(Rectangle())
            .gesture(timelineGesture(range: range, width: width))
        }
        .frame(height: 56)
    }

    /// The timeline's drag interaction, extracted from `timeline(range:)` so the view
    /// builder stays small. Unlike the editor's slider there is no preview to resume,
    /// so the gesture needs no `onEnded`.
    private func timelineGesture(
        range: ClosedRange<TimeInterval>, width: CGFloat
    ) -> some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in
                if state == nil {
                    let touched = self.time(at: value.location.x, in: range, width: width)
                    state = TimelineDrag(
                        handle: nearestHandle(to: touched), range: range, width: width)
                }
            }
            .onChanged { value in
                guard let drag else { return }
                let touched = self.time(
                    at: value.location.x, in: drag.range, width: drag.width)
                switch drag.handle {
                case .start: trimStart(to: touched)
                case .end: trimEnd(to: touched)
                }
            }
    }

    /// The handle nearer to a touch, so a drag anywhere on the timeline grabs something
    /// sensible instead of requiring a hit on the 12pt handle.
    private func nearestHandle(to time: TimeInterval) -> ActiveHandle {
        abs(time - window.startTime) <= abs(time - window.endTime) ? .start : .end
    }

    /// Drags the start handle to `time` — the editor's trim rule via the shared
    /// pure helper, so the two surfaces can never diverge silently.
    private func trimStart(to time: TimeInterval) {
        let newWindow = ClipEditorViewModel.trimmedStart(window, to: time)
        guard newWindow.startTime != window.startTime else { return }
        window = newWindow
    }

    /// Drags the end handle to `time` — the same shared rule.
    private func trimEnd(to time: TimeInterval) {
        let newWindow = ClipEditorViewModel.trimmedEnd(
            window, to: time, duration: duration)
        guard newWindow.endTime != window.endTime else { return }
        window = newWindow
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
            // Tenth-second steps for VoiceOver, like the editor's slider.
            trim(time + (direction == .increment ? 0.1 : -0.1))
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
