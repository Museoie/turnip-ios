import SwiftUI

/// A circular icon button floating directly over media (video/photo content) — Processing's
/// cancel and back chevron (with `ScrimTextButton`'s "Clip it" across from them), the editor's
/// and the clip list's back chevrons, the editor's Auto follow and Auto rotate toggles, Camera's
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
    /// A `LocalizedStringKey` so call-site literals localize: a `String` parameter
    /// would pass the stored value through to `.accessibilityLabel(_:)`, which resolves
    /// to the non-localizing `StringProtocol` overload.
    let accessibilityLabel: LocalizedStringKey
    var diameter: CGFloat = 44
    var font: Font = .body.weight(.semibold)
    var style: Style = .glass
    /// The circle's color while a toggle is on, in place of the glass or scrim; `nil` while it is
    /// off, and for a button that isn't a toggle.
    var tint: Color?
    /// Shows a spinner in place of the glyph while the button's work runs.
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ScrimIconGlyph(
                systemImage: systemImage, diameter: diameter, font: font, style: style, tint: tint,
                isBusy: isBusy)
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
}

/// `ScrimIconButton`'s drawn circle on its own, for a control whose label has to be a bare glyph
/// rather than a nested `Button`: a `Menu`'s, which a nested `Button` would fight for the tap.
struct ScrimIconGlyph: View {
    let systemImage: String
    var diameter: CGFloat = 44
    var font: Font = .body.weight(.semibold)
    var style: ScrimIconButton.Style = .glass
    var tint: Color?
    var isBusy = false

    var body: some View {
        let image = ZStack {
            if isBusy {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: systemImage)
                    .font(font)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        let scrim = tint ?? Color.black.opacity(0.4)
        switch style {
        case .glass:
            if #available(iOS 26.0, *) {
                if let tint {
                    // Tinted glass rather than a flat fill, so an on toggle stays the same
                    // material as the buttons beside it.
                    image.glassEffect(.regular.tint(tint), in: Circle())
                } else {
                    image.glassEffect(in: Circle())
                }
            } else {
                image.background(scrim, in: Circle())
            }
        case .scrim:
            image.background(scrim, in: Circle())
        }
    }
}
