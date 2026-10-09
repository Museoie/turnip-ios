import SwiftUI

/// The app's one full-width prominent call-to-action, pinned to the bottom of a
/// screen via `.safeAreaInset`: "Analyze clips", "Export N clips", "Done". A shared
/// component rather than three ad hoc buttons — `.borderedProminent`'s background
/// ignores a `.frame(maxWidth:)` applied to the `Button` itself, so a hand-rolled
/// version quietly renders as a small centered pill instead of the full-width bar it
/// looks like everywhere else; the frame has to go on the label, which is the one
/// thing every ad hoc copy got wrong. Wrapping that gotcha here means every caller
/// gets the real full-width button.
///
/// An optional `SecondaryAction` draws a plain text button under the prominent one, inside
/// the same material bar — the quieter alternative to the main call ("Clip manually" under
/// "Analyze clips"). Part of this component rather than a sibling the caller stacks below
/// it: a button outside the bar would sit on the screen's own backdrop between the bar and
/// the home indicator, reading as a stray link rather than the bar's second choice.
struct PrimaryActionBar: View {
    /// The quieter second choice under the prominent button.
    struct SecondaryAction {
        let title: String
        let action: () -> Void

        init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
    }

    let title: String
    let isEnabled: Bool
    let action: () -> Void
    let secondary: SecondaryAction?

    init(
        _ title: String,
        isEnabled: Bool = true,
        secondary: SecondaryAction? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.secondary = secondary
        self.action = action
    }

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isEnabled)
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(.borderless)
                    .disabled(!isEnabled)
            }
        }
        .padding()
        .background(.thinMaterial)
    }
}
