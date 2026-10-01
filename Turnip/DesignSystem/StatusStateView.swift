import SwiftUI

/// The app's one "nothing to show, here's why" layout — an icon, a title, a message,
/// and optional actions below. Every empty/denied/error state in the app (Home's
/// empty grid, Photos/Camera access denied, Processing's failure, the editor's load
/// failure) is this same shape; before this existed they'd drifted into two different
/// icon sizes and title styles across screens that otherwise agree.
struct StatusStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions
        }
        .padding(32)
    }
}
