import SwiftUI

/// `ScrimIconButton`'s text counterpart: a short label in a capsule floating directly over
/// media, where a navigation bar would put a text item — Processing's "Clip it". Real Liquid
/// Glass on iOS 26, the translucent dark scrim before, for the same reasons the icon button
/// gives; the same 44 pt height, so the two sit level in one header row.
struct ScrimTextButton: View {
    /// A `LocalizedStringKey` so call-site literals localize: a `String` would pass through
    /// `Text`'s non-localizing `StringProtocol` overload.
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var label: some View {
        let text = Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
        if #available(iOS 26.0, *) {
            text.glassEffect(in: Capsule())
        } else {
            text.background(.black.opacity(0.4), in: Capsule())
        }
    }
}
