import SwiftUI

/// A transient, top-centered notice in Liquid Glass chrome — real `.glassEffect` on iOS 26
/// (matching `ScrimIconButton`/`RootTabView`'s floating tab bar), an `.ultraThinMaterial`
/// capsule pre-26. Dismissed by a tap or automatically after `autoDismissAfter` seconds.
struct GlassNoticeView: View {
    let message: String
    @Binding var isPresented: Bool
    var autoDismissAfter: TimeInterval = 5

    var body: some View {
        Button(action: dismiss) {
            let text = Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            if #available(iOS 26.0, *) {
                text.glassEffect(in: Capsule())
            } else {
                text.background(.ultraThinMaterial, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .task {
            try? await Task.sleep(for: .seconds(autoDismissAfter))
            guard !Task.isCancelled else { return }
            dismiss()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { isPresented = false }
    }
}

#Preview {
    GlassNoticeView(message: "No tricks found", isPresented: .constant(true))
        .padding()
        .background(Color.black)
}
