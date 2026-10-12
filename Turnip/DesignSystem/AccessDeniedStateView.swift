import SwiftUI

/// A permission's denied / restricted empty state: the `StatusStateView` shape, plus an
/// "Open Settings" link unless a restriction means Settings can't help either.
struct AccessDeniedStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let restricted: Bool
    /// The link's accessibility identifier, for screens a UI test drives; `nil` leaves it
    /// unset, so two mounted pages never expose the same identifier.
    var openSettingsIdentifier: String?

    var body: some View {
        StatusStateView(systemImage: systemImage, title: title, message: message) {
            if !restricted, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                let link = Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                if let openSettingsIdentifier {
                    link.accessibilityIdentifier(openSettingsIdentifier)
                } else {
                    link
                }
            }
        }
    }
}
