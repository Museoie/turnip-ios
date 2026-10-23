import SwiftUI

/// A transient, top-centered notice in Liquid Glass chrome — real `.glassEffect` on iOS 26
/// (matching `ScrimIconButton`/`RootTabView`'s floating tab bar), an `.ultraThinMaterial`
/// capsule pre-26. Dismissed by a tap or automatically after `autoDismissAfter` seconds.
struct GlassNoticeView: View {
    let message: String
    @Binding var isPresented: Bool
    var autoDismissAfter: TimeInterval = 5
    /// Reads whether a screen reader is driving the screen. A notice on a timer can expire
    /// before VoiceOver has worked its way over to read it, so under a screen reader the
    /// notice waits to be dismissed instead of dismissing itself. Injected rather than read
    /// inline so the branch is reachable without a running screen reader.
    var isScreenReaderRunning: () -> Bool = { UIAccessibility.isVoiceOverRunning }
    @Environment(\.glassNoticesDismissThemselves) private var dismissesItself

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
            guard dismissesItself, !isScreenReaderRunning() else { return }
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

/// Whether a `GlassNoticeView` dismisses itself on its timer. Off, every notice waits to be
/// dismissed, as it does under a screen reader: the UI test harnesses turn it off for a test
/// that checks a notice appeared, which would otherwise race the notice's timer against the
/// test runner's queries, and a loaded CI runner can answer a query after the notice is gone.
private struct GlassNoticesDismissThemselvesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var glassNoticesDismissThemselves: Bool {
        get { self[GlassNoticesDismissThemselvesKey.self] }
        set { self[GlassNoticesDismissThemselvesKey.self] = newValue }
    }
}

#Preview {
    GlassNoticeView(message: "No tricks found", isPresented: .constant(true))
        .padding()
        .background(Color.black)
}
