import Foundation
import SwiftUI

/// The editor's scrub bar: the asset timeline around the draft window, with drag handles on
/// start/end and a playhead tracking preview playback (`docs/UIUX.md` § "Clip Detail /
/// Editor").
///
/// The timeline spans the draft window plus context (`ClipEditorViewModel.visibleRange`),
/// not the whole asset — on a multi-minute video full-asset handles would be sub-pixel.
/// Dragging anywhere on the timeline grabs the nearer handle, and the drag's time mapping
/// is frozen for the gesture so the draft window's own growth can't shift the scale
/// mid-drag. Handle drags report through the view model, so the crop rect re-derives live.
struct TrimSliderView: View {
    @ObservedObject var viewModel: ClipEditorViewModel
    @GestureState private var drag: TimelineDrag?
    // SwiftUI resets `@GestureState` to nil when the gesture's lifecycle ends, but
    // `DragGesture.onEnded` does not fire on a system-cancelled drag (phone call,
    // Control Center) — so the in-flight drag's presence, not its callbacks, is the
    // reliable signal that a trim interaction is over.

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
        if let range = viewModel.visibleRange {
            // Frozen for the gesture's duration: the drag's time mapping is captured once in
            // `TimelineDrag`, so the drawing must use that same range — the live range
            // tracks the growing window and would let the handles drift out from under the
            // finger mid-drag.
            let drawRange = drag?.range ?? range
            VStack(spacing: 4) {
                timeline(range: drawRange)
                HStack {
                    Text(ClipEditorViewModel.timeLabel(viewModel.window.startTime))
                    Spacer()
                    Text(viewModel.durationLabel)
                    Spacer()
                    Text(ClipEditorViewModel.timeLabel(viewModel.window.endTime))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Trim range \(ClipEditorViewModel.timeLabel(viewModel.window.startTime)) to "
                        + ClipEditorViewModel.timeLabel(viewModel.window.endTime))
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
            .frame(height: 56)
            .contentShape(Rectangle())
            .gesture(timelineGesture(range: range, width: width))
        }
        .frame(height: 56)
        .onChange(of: drag != nil) { isDragging in
            // `onEnded` never fires when the system cancels the drag (call, Control
            // Center); the GestureState reset above is the only signal in that case.
            // If the trim latch is still set, `finishTrim()` never ran, so the player
            // would stay paused and `tick` would suppress the loop-back for the rest
            // of the session. The call is idempotent (clear + seek + play), so this
            // can't fight the normal `onEnded` path — whichever fires first wins.
            if !isDragging, viewModel.isTrimming {
                viewModel.finishTrim()
            }
        }
    }

    /// The timeline's drag interaction, extracted from `timeline(range:)` so the view
    /// builder stays within the function-body length limit.
    private func timelineGesture(range: ClosedRange<TimeInterval>, width: CGFloat) -> some Gesture {
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
                case .start: viewModel.trimStart(to: touched)
                case .end: viewModel.trimEnd(to: touched)
                }
            }
            .onEnded { _ in
                viewModel.finishTrim()
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
        .accessibilityValue(ClipEditorViewModel.timeLabel(time))
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
