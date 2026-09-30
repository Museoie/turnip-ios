import SwiftUI

/// A circular icon button floating directly over media (video/photo content) — the
/// camera screen's cancel/exposure/flash/flip buttons, Processing's cancel and back
/// chevron. Real Liquid Glass on iOS 26 (`.glassEffect`), same as the floating tab bar
/// (`RootTabView`); a translucent dark scrim behind the glyph pre-26, where there's no
/// system glass to render and contrast against an arbitrary frame still needs a fixed
/// backing. One shared definition instead of each screen re-declaring the same
/// background; `diameter`/`font` stay per-call-site since a full-screen overlay button
/// and a small in-tile corner button are genuinely different scales, not the same
/// button drifting.
struct ScrimIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var diameter: CGFloat = 44
    var font: Font = .body.weight(.semibold)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph
                // Touch-target floor (docs/ACCESSIBILITY.md's 44x44 pt minimum), applied
                // on the label so it's part of the Button's own hit-testing region —
                // same placement `BackChevronButton` uses. A no-op at the 44 pt default;
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
        if #available(iOS 26.0, *) {
            image.glassEffect(in: Circle())
        } else {
            image.background(.black.opacity(0.4), in: Circle())
        }
    }
}
