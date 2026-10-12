import SwiftUI

extension View {
    /// The app's one-button failure alert: shown while `message` is non-nil, and dismissing
    /// it clears `message`, so the owning state is the only source of truth for whether the
    /// alert is up. `title` stays a `LocalizedStringKey` so call-site literals localize.
    func errorAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
