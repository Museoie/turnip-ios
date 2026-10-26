import SwiftUI

/// Follow mode's lane (`docs/UIUX.md` § "Two framing modes, Still and Follow"): the follow
/// crop's keyframes over the trim window, between the crop buttons and the trim timeline.
///
/// It spans the window rather than the whole video, so a 4-second clip from a 3-minute take
/// still gets the lane's whole width. Each keyframe is a diamond, hollow while it is where Auto
/// follow put it and filled once the user set or moved it; one a trim has left outside the
/// window is a marker at that end, since it still shapes the curve there. A drag anywhere
/// scrubs the playhead through the window with the trim timeline's vertical drag-to-slow
/// precision (`ScrubCalculator`), and pauses playback; tapping a diamond jumps to it. The
/// button at the trailing end adds a keyframe at the playhead or removes the one under it, and
/// a long press on a diamond jumps to it and offers to remove it or to give every keyframe its
/// zoom and turn. For VoiceOver the lane is adjustable, a tenth of a second a swipe, the trim
/// handles' step.
struct FollowLaneView: View {
    @ObservedObject var viewModel: ClipEditorViewModel

    static let height: CGFloat = 44
    /// Room at each end for a diamond on the window's edge and the markers past it.
    private static let inset: CGFloat = 22
    private static let diamondSize: CGFloat = 16

    /// The window the drag maps onto, frozen for the gesture, and the playhead time and drag
    /// translation the precision scrub is measured from.
    private struct LaneDrag {
        let window: TrickWindow
        let width: CGFloat
        let startTime: TimeInterval
        let startTranslation: CGSize
    }

    @State private var drag: LaneDrag?
    /// Waits out a still press on a diamond; cancelled when the finger moves or lifts first.
    @State private var longPress: Task<Void, Never>?
    /// Set once a press has acted as a long press, so lifting doesn't also jump the playhead.
    @State private var didLongPress = false
    /// The keyframe a long press is offering choices for.
    @State private var pressedKeyframe: FollowKeyframe?
    private static let longPressDuration: TimeInterval = 0.5
    /// How far a touch may sit from a diamond's center and still be on it.
    private static let diamondReach: CGFloat = 22

    var body: some View {
        HStack(spacing: 4) {
            track
            keyframeButton
        }
        .frame(height: Self.height)
        .confirmationDialog(
            "Keyframe", isPresented: isOfferingKeyframeChoices, titleVisibility: .hidden,
            presenting: pressedKeyframe
        ) { keyframe in
            Button("Apply zoom and turn to all keyframes") {
                viewModel.applyZoomAndTurnToAllKeyframes(from: keyframe)
            }
            .accessibilityIdentifier("follow-apply-to-all-button")
            Button("Remove keyframe", role: .destructive) {
                viewModel.removeKeyframe(keyframe)
            }
            .accessibilityIdentifier("follow-remove-keyframe-button")
        }
    }

    private var isOfferingKeyframeChoices: Binding<Bool> {
        Binding(get: { pressedKeyframe != nil }, set: { if !$0 { pressedKeyframe = nil } })
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let window = drag?.window ?? viewModel.window
            ZStack(alignment: .leading) {
                // Translucent rather than a system gray: the lane sits on the frosted surround,
                // which every dark gray all but vanishes into.
                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(height: 28)
                    .padding(.horizontal, Self.inset / 2)
                ForEach(Array(viewModel.followKeyframes.enumerated()), id: \.offset) { _, keyframe in
                    marker(for: keyframe, in: window, width: width)
                }
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: Self.height - 6)
                    .offset(x: x(of: viewModel.playbackTime, in: window, width: width) - 1.5)
                    .allowsHitTesting(false)
            }
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Follow keyframes")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("follow-lane")
        .accessibilityAdjustableAction { direction in
            viewModel.scrubFollowLane(to: viewModel.currentTime + (direction == .increment ? 0.1 : -0.1))
        }
    }

    /// Adds a keyframe at the playhead, or removes the one under it
    /// (`ClipEditorViewModel.keyframeReach`).
    private var keyframeButton: some View {
        let removes = viewModel.keyframeAtPlayhead != nil
        return Button {
            viewModel.toggleKeyframeAtPlayhead()
        } label: {
            Image(systemName: removes ? "minus.diamond" : "plus.diamond")
                .font(.title3)
                .frame(width: Self.height, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.yellow)
        .accessibilityLabel(removes ? "Remove keyframe" : "Add keyframe")
        .accessibilityIdentifier("follow-keyframe-button")
    }

    /// A diamond inside the window; past an end, a smaller one at that end with a chevron
    /// pointing the way it lies.
    @ViewBuilder
    private func marker(for keyframe: FollowKeyframe, in window: TrickWindow, width: CGFloat) -> some View {
        if keyframe.time < window.startTime || keyframe.time > window.endTime {
            let isBefore = keyframe.time < window.startTime
            Image(systemName: isBefore ? "chevron.left" : "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: Self.inset / 2, height: Self.height)
                .offset(x: isBefore ? 0 : width - Self.inset / 2)
                .allowsHitTesting(false)
        } else {
            FollowKeyframeDiamond(isUserSet: !keyframe.isAutoFollows)
                .frame(width: Self.diamondSize, height: Self.diamondSize)
                .offset(x: x(of: keyframe.time, in: window, width: width) - Self.diamondSize / 2)
                .allowsHitTesting(false)
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let drag else {
                    let window = viewModel.window
                    let touched = time(at: value.startLocation.x, in: window, width: width)
                    viewModel.scrubFollowLane(to: touched)
                    self.drag = LaneDrag(
                        window: window, width: width, startTime: touched, startTranslation: value.translation)
                    didLongPress = false
                    armLongPress(at: value.startLocation.x, in: window, width: width)
                    return
                }
                if hypot(value.translation.width, value.translation.height) >= 6 {
                    longPress?.cancel()
                }
                guard !didLongPress else { return }
                let moved = CGSize(
                    width: value.translation.width - drag.startTranslation.width,
                    height: value.translation.height - drag.startTranslation.height)
                let usable = max(drag.width - 2 * Self.inset, 1)
                let result = ScrubCalculator.calculate(
                    translation: moved, viewportSize: CGSize(width: usable, height: Self.height))
                let span = drag.window.endTime - drag.window.startTime
                viewModel.scrubFollowLane(to: drag.startTime + result.timelineDelta / 2 * span)
            }
            .onEnded { value in
                longPress?.cancel()
                defer { drag = nil }
                guard let drag, !didLongPress, hypot(value.translation.width, value.translation.height) < 6
                else { return }
                // A tap on a diamond lands on its keyframe exactly.
                if let keyframe = diamond(at: value.startLocation.x, in: drag.window, width: width) {
                    viewModel.scrubFollowLane(to: keyframe.time)
                }
            }
    }

    /// A still press on a diamond, held: the playhead goes to its keyframe, and a choice opens
    /// between removing it, as the trailing button would there, and giving every keyframe its
    /// zoom and turn.
    private func armLongPress(at locationX: CGFloat, in window: TrickWindow, width: CGFloat) {
        longPress?.cancel()
        guard let keyframe = diamond(at: locationX, in: window, width: width) else { return }
        longPress = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.longPressDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            didLongPress = true
            viewModel.scrubFollowLane(to: keyframe.time)
            pressedKeyframe = keyframe
        }
    }

    /// The keyframe whose diamond is under `locationX`, the nearest if two are.
    private func diamond(at locationX: CGFloat, in window: TrickWindow, width: CGFloat) -> FollowKeyframe? {
        viewModel.followKeyframes
            .filter { $0.time >= window.startTime && $0.time <= window.endTime }
            .map { (keyframe: $0, distance: abs(x(of: $0.time, in: window, width: width) - locationX)) }
            .filter { $0.distance <= Self.diamondReach }
            .min { $0.distance < $1.distance }?
            .keyframe
    }

    private func x(of time: TimeInterval, in window: TrickWindow, width: CGFloat) -> CGFloat {
        let span = window.endTime - window.startTime
        let usable = width - 2 * Self.inset
        guard span > 0, usable > 0 else { return Self.inset }
        let fraction = min(max((time - window.startTime) / span, 0), 1)
        return Self.inset + CGFloat(fraction) * usable
    }

    private func time(at x: CGFloat, in window: TrickWindow, width: CGFloat) -> TimeInterval {
        let usable = width - 2 * Self.inset
        guard usable > 0 else { return window.startTime }
        let fraction = min(max((x - Self.inset) / usable, 0), 1)
        return window.startTime + TimeInterval(fraction) * (window.endTime - window.startTime)
    }

    private var accessibilityValue: String {
        let count = viewModel.followKeyframes.count
        let playhead = ClipDurationFormatter.accessibilityString(from: viewModel.playbackTime)
        let keyframes = count == 1 ? String(localized: "1 keyframe") : String(localized: "\(count) keyframes")
        return String(localized: "\(keyframes), playhead at \(playhead)")
    }
}

/// A keyframe's mark: hollow while it is where Auto follow put it, filled yellow once the user
/// has set or moved it — the split Photos' Cinematic editor draws between automatic and manual
/// focus points.
struct FollowKeyframeDiamond: View {
    let isUserSet: Bool

    var body: some View {
        let diamond = Rectangle().rotation(.degrees(45)).scale(0.72)
        if isUserSet {
            diamond.fill(Color.yellow)
        } else {
            diamond.stroke(.white, lineWidth: 2)
        }
    }
}
