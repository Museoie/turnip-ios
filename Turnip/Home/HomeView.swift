import Photos
import SwiftUI

/// Home / Video Gallery per docs/UIUX.md: the entry screen *is* the video picker — a 3-column
/// grid of every video in the Photos library. Tapping a tile is the "pick" action.
struct HomeView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()

    var body: some View {
        NavigationStack(path: $viewModel.path) {
            content
                .navigationTitle("Turnip")
                .navigationDestination(for: SelectedVideo.self) { video in
                    // The pose diagnostic is the only consumer of a picked video today. This is
                    // the one place to swap in the Processing screen.
                    PoseDiagnosticView(video: video)
                }
        }
        .task { await viewModel.start() }
        .alert("Couldn't open video", isPresented: errorPresented) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.authorization {
        case .notDetermined:
            // The system permission prompt is up; nothing useful to draw behind it.
            ProgressView()
        case .denied(let restricted):
            PhotosAccessDeniedView(restricted: restricted)
        case .authorized, .limited:
            VideoGalleryView(viewModel: viewModel)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

/// The grid plus its two decorations: a "select more" banner under limited access, and a bottom
/// banner with a cancel button while a tapped video is being fetched.
struct VideoGalleryView: View {
    @ObservedObject var viewModel: VideoLibraryViewModel

    private static let spacing: CGFloat = 2
    private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)

    var body: some View {
        Group {
            if !viewModel.hasLoaded {
                // Not yet the same thing as "no videos" — the first fetch hasn't run.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.videos.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if viewModel.authorization == .limited {
                LimitedAccessBanner(selectMore: viewModel.presentLimitedLibraryPicker)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let resolution = viewModel.resolution {
                ResolutionBanner(resolution: resolution, cancel: viewModel.cancelSelection)
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(Array(viewModel.videos.enumerated()), id: \.element.localIdentifier) { index, asset in
                    Button {
                        viewModel.select(asset)
                    } label: {
                        VideoTileView(
                            asset: asset,
                            thumbnails: viewModel.thumbnails,
                            revision: viewModel.thumbnails.revision(for: asset),
                            isResolving: viewModel.isResolving(asset),
                            downloadProgress: viewModel.downloadProgress(for: asset)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.resolution != nil)
                    .onAppear { viewModel.tileAppeared(at: index) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(viewModel.authorization == .limited ? "No videos selected" : "No videos")
                .font(.title3.weight(.semibold))
            Text(
                viewModel.authorization == .limited
                    ? "Turnip can only see the videos you choose. Select some to get started."
                    : "Record a tricking session, and it'll show up here."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LimitedAccessBanner: View {
    let selectMore: () -> Void

    var body: some View {
        HStack {
            Text("Turnip can only see the videos you've selected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select More…", action: selectMore)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ResolutionBanner: View {
    let resolution: VideoLibraryViewModel.Resolution
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                if let progress = resolution.downloadProgress {
                    Text("Downloading from iCloud…")
                        .font(.subheadline)
                    ProgressView(value: progress)
                } else {
                    Text("Preparing video…")
                        .font(.subheadline)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding()
        .background(.bar)
    }
}

/// Denied / restricted empty state. There's no picker fallback once Home is the gallery, so the
/// only way forward is Settings — unless a restriction means Settings can't help either.
struct PhotosAccessDeniedView: View {
    let restricted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Turnip needs access to your videos")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(
                restricted
                    ? "Photos access is restricted on this device, so Turnip can't show your videos."
                    : "Turnip finds and trims tricks in recordings from your Photos library. "
                        + "Allow access in Settings to get started."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if !restricted, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Denied") {
    NavigationStack {
        PhotosAccessDeniedView(restricted: false)
            .navigationTitle("Turnip")
    }
}

#Preview("Restricted") {
    NavigationStack {
        PhotosAccessDeniedView(restricted: true)
            .navigationTitle("Turnip")
    }
}
