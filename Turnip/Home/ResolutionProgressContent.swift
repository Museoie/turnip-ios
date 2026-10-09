import SwiftUI

extension VideoLibraryViewModel.Resolution {
    static let preparingTitle: LocalizedStringKey = "Preparing video…"

    /// The phase a resolve is in, as every progress surface words it: an iCloud download once
    /// PhotoKit reports a fraction, "preparing" before that and through the composition export.
    var statusTitle: LocalizedStringKey {
        downloadProgress == nil ? Self.preparingTitle : "Downloading from iCloud…"
    }
}

/// The white-on-dark progress stack shown over a poster while a video resolves — Home's
/// first video (`ResolvingDestination`) and Processing's browse to a neighbor
/// (`ProcessingView.browsingOverlay`) are the same situation, so they report it the same way:
/// a real bar for an iCloud download, an indeterminate spinner otherwise. Callers supply the
/// background, since one is a box over the poster and the other a full-screen dim.
struct ResolutionProgressContent: View {
    /// `nil` before the resolve has reported anything — read as "preparing".
    let resolution: VideoLibraryViewModel.Resolution?
    /// `nil` hides the Cancel button.
    let cancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(resolution?.statusTitle ?? VideoLibraryViewModel.Resolution.preparingTitle)
                .font(.subheadline)
                .foregroundStyle(.white)
            if let progress = resolution?.downloadProgress {
                ProgressView(value: progress)
                    .tint(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
            if let cancel {
                Button("Cancel", role: .cancel, action: cancel)
                    .tint(.white)
            }
        }
        .padding(32)
    }
}
