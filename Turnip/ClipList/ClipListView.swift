import AVFoundation
import SwiftUI

/// The triage screen (`docs/UIUX.md` § "Clip List (triage)"): one card per
/// detected trick window — thumbnail, duration, keep/discard toggle — plus the
/// "Export N clips" action.
///
/// The processing screen pushes this with the pipeline's output. Card taps navigate
/// to the clip editor and the export action to export confirmation; both destinations
/// are placeholders owned by the follow-up screen PRs (see
/// `ClipListPlaceholders.swift`). This view deliberately
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
            case .editor(let id):
                // The editor binds back into the list so keep/discard changes commit
                // on back-navigation (docs/UIUX.md § "Clip Detail / Editor").
                if let item = viewModel.binding(for: id) {
                    ClipEditorPlaceholderView(item: item)
                }
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

/// The clip list's navigation exit: a card tap goes to the editor. The destination
/// carries the item's id rather than the item itself so the editor can bind back into
/// the view model's list — edits commit to the triage list on back-navigation instead
/// of dying with a value copy.
/// The export action uses `isPresented` instead, so the destination reads the kept clips at
/// navigation time rather than at body-evaluation time.
private enum ClipListDestination: Hashable {
    case editor(UUID)
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
    @State private var placeholderRatio: CGFloat?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: ClipListDestination.editor(item.id)) {
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
            // Fetch the displayed-space placeholder ratio alongside the thumbnail. The
            // ratio is cached per asset, and the thumbnail shares one in-flight decode
            // per card — a `.task` re-fire joins the decode already running (or reads
            // the cached image) instead of seeking the same frame a second time.
            async let ratio = viewModel.placeholderAspectRatio(for: item)
            async let image = viewModel.thumbnail(for: item)
            placeholderRatio = await ratio
            thumbnail = await image
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = thumbnail {
            // The generator hands back the displayed (upright) frame, so `.up` is exact —
            // no UIKit bridge needed.
            Image(decorative: image, scale: 1.0, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(placeholderRatio ?? encodedSpaceRatio, contentMode: .fit)
                .overlay { ProgressView() }
        }
    }

    /// The crop rect's own ratio (encoded space): the best guess before the track
    /// geometry loads. The view model replaces it with the displayed-space ratio —
    /// the space the decoded thumbnail renders in — as soon as the track's
    /// `preferredTransform` is known, so cards don't reflow when thumbnails land.
    private var encodedSpaceRatio: CGFloat {
        let width = CGFloat(item.cropRect.width), height = CGFloat(item.cropRect.height)
        guard width > 0, height > 0 else { return 9.0 / 16.0 }
        return width / height
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
            // AVAsset is abstract and throws at runtime; AVURLAsset is the concrete
            // subclass. The URL resolves to nothing — the preview shows the
            // placeholder tiles, which is the honest fallback.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        )
    }
}
