import AVFoundation
import SwiftUI

/// The triage screen (`docs/UIUX.md` § "Clip List (triage)", issue #11): one card per
/// detected trick window — thumbnail, duration, keep/discard toggle — plus the
/// "Export N clips" action.
///
/// The processing screen (#17) pushes this with the pipeline's output. Card taps navigate
/// to the clip editor and the export action to export confirmation; both destinations are
/// placeholders owned by #18/#19 (see `ClipListPlaceholders.swift`). This view deliberately
/// declares no `NavigationStack` of its own — it lives on the flow's shared stack.
struct ClipListView: View {
    @StateObject private var viewModel: ClipListViewModel
    @State private var showingExport = false

    init(
        items: [ClipListItem],
        asset: AVAsset,
        loader: ClipThumbnailLoader = ClipThumbnailLoader()
    ) {
        _viewModel = StateObject(wrappedValue: ClipListViewModel(
            items: items, asset: asset, loader: loader))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 16
            ) {
                ForEach(viewModel.items) { item in
                    ClipCardView(item: item, viewModel: viewModel)
                }
            }
            .padding()
        }
        .navigationTitle("Clips")
        .navigationDestination(for: ClipListDestination.self) { destination in
            switch destination {
            case .editor(let item):
                ClipEditorPlaceholderView(item: item)
            }
        }
        .navigationDestination(isPresented: $showingExport) {
            ExportConfirmationPlaceholderView(items: viewModel.keptItems)
        }
        .safeAreaInset(edge: .bottom) {
            Button(viewModel.exportTitle) { showingExport = true }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canExport)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.thinMaterial)
        }
    }
}

/// The clip list's value-typed navigation exit: a card tap goes to the editor (#18). The
/// export action uses `isPresented` instead, so the destination reads the kept clips at
/// navigation time rather than at body-evaluation time.
private enum ClipListDestination: Hashable {
    case editor(ClipListItem)
}

/// One triage card: the clip's thumbnail (frame at the window midpoint, cropped to its
/// crop rect), its duration, and the keep/discard toggle.
///
/// The toggle sits *outside* the `NavigationLink` as a `ZStack` overlay so tapping it
/// never triggers the card's navigation to the editor — the issue calls the toggle a
/// quick action that must not require opening detail.
private struct ClipCardView: View {
    let item: ClipListItem
    @ObservedObject var viewModel: ClipListViewModel
    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: ClipListDestination.editor(item)) {
                VStack(alignment: .leading, spacing: 8) {
                    thumbnailView
                    Text(item.durationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .opacity(item.isKept ? 1 : 0.45)

            Button(action: { viewModel.toggleKeep(item) }) {
                Image(systemName: item.isKept ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel(item.isKept ? "Discard clip" : "Keep clip")
        }
        .task {
            thumbnail = await viewModel.thumbnail(for: item)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = thumbnail {
            Image(uiImage: UIImage(cgImage: image))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .overlay { ProgressView() }
        }
    }
}

#Preview {
    NavigationStack {
        ClipListView(
            items: [
                ClipListItem(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
                ),
                ClipListItem(
                    window: TrickWindow(startTime: 9, endTime: 11.5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
                    isKept: false
                ),
            ],
            asset: AVAsset()
        )
    }
}
