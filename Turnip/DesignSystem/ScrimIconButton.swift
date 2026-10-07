import SwiftUI

/// A circular icon button floating directly over media (video/photo content) — Processing's
/// cancel and back chevron, the editor's and the clip list's back chevrons, Camera's
/// cancel/exposure/flash/flip buttons (forced to `.scrim`; see `Style`). The one shape every
/// screen's chevron takes, so the control reads the same across the flow's cross-fades.
/// Real Liquid Glass on iOS 26 (`.glassEffect`) by default, same as the floating
/// tab bar (`RootTabView`); a translucent dark scrim behind the glyph pre-26, where there's no
/// system glass to render and contrast against an arbitrary frame still needs a fixed
/// backing. One shared definition instead of each screen re-declaring the same background;
/// `diameter`/`font` stay per-call-site since a full-screen overlay button and a small
/// in-tile corner button are genuinely different scales, not the same button drifting.
struct ScrimIconButton: View {
    /// `.glass` picks up real Liquid Glass on iOS 26 (the default); `.scrim` forces the flat
    /// dark backing on every OS — Camera's buttons use it: glass didn't read well floating
    /// directly over a live camera feed, unlike Processing's buttons over a paused frame.
    enum Style {
        case glass
        case scrim
    }

    let systemImage: String
    let accessibilityLabel: String
    var diameter: CGFloat = 44
    var font: Font = .body.weight(.semibold)
    var style: Style = .glass
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph
                // Touch-target floor (docs/ACCESSIBILITY.md's 44x44 pt minimum), applied
                // on the label so it's part of the Button's own hit-testing region. A
                // no-op at the 44 pt default;
                // expands the tappable area around a smaller `diameter` without
                // changing what's drawn.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: systemImage)
            .font(font)
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
        switch style {
        case .glass:
            if #available(iOS 26.0, *) {
                image.glassEffect(in: Circle())
            } else {
                image.background(.black.opacity(0.4), in: Circle())
            }
        case .scrim:
            image.background(.black.opacity(0.4), in: Circle())
        }
    }
}
