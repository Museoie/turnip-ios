import AVFoundation
import SwiftUI

/// Clip List (`docs/UIUX.md` § "Clip List"): where an analysis lands, where Processing's "Clip it"
/// goes, and where a camera take live inference fully covered lands. A grid with a tile per clip
/// (`ClipCard`), each looping its window with the framing it exports with, carrying the timeline of
/// where it sits in the video, over a caption with its length and the names it has been given.
///
/// Tapping a tile pushes Name Clips (`NameClipsView`) on that clip, which pages through the rest
/// from there; the bottom bar's "Name clips" pushes it on the first clip. Both screens work on this
/// screen's `ClipListViewModel`, so a name, an edit, a clip added or removed there is on the grid on
/// the way back.
///
/// The grid doesn't save: "Save Clips" stays on Name Clips' last clip, so every clip has been on
/// screen as a page, with the names the trick model filled in as chips that can be removed, before
/// it is saved. The header's "+" adds a clip. With no clip, the screen offers "Analyze clips"
/// (`analyze`) and "Clip manually". The back chevron pops to Home. This view declares no
/// `NavigationStack` of its own.
struct ClipListView: View {
    @StateObject private var viewModel: ClipListViewModel
    private let vocabulary: VocabularyStore
    private let account: FarmAccount
    private let outbox: ContributionOutbox
    /// A run that found nothing says so; a video that arrived by "Clip it" wasn't looked at.
    let showsNoTricksFound: Bool
    let popToRoot: () -> Void
    /// Leaves for Processing to analyze the video: the empty state's "Analyze clips". Nil where
    /// no Processing screen sits under this one (a camera take live inference fully covered,
    /// which has been analyzed), and the empty state then offers "Clip manually" alone.
    let analyze: (() -> Void)?

    /// Whether Name Clips is pushed over the grid, and the clip it opened on.
    @State private var isNaming = false
    @State private var namingStart = 0
    /// The clip "+" or "Clip manually" just added, which the grid scrolls to.
    @State private var addedClipID: UUID?
    /// iPhone Duo's vertical bar, which the bar's items go down instead.
    @Environment(\.verticalBar) private var verticalBar

    init(
        items: [ClipListItem],
        poseFrames: [PoseFrameResult] = [],
        people: [PoseTrack] = [],
        windowEmbeddings: [WindowEmbeddings] = [],
        asset: AVAsset,
        assetIdentifier: String,
        duration: TimeInterval,
        loader: ClipThumbnailLoader = ClipThumbnailLoader(),
        showsNoTricksFound: Bool = false,
        vocabulary: VocabularyStore = .shared,
        account: FarmAccount = .shared,
        outbox: ContributionOutbox = .shared,
        popToRoot: @escaping () -> Void = {},
        analyze: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: ClipListViewModel(
            items: items, poseFrames: poseFrames, people: people, windowEmbeddings: windowEmbeddings, asset: asset,
            assetIdentifier: assetIdentifier, duration: duration, loader: loader))
        self.vocabulary = vocabulary
        self.account = account
        self.outbox = outbox
        self.showsNoTricksFound = showsNoTricksFound
        self.popToRoot = popToRoot
        self.analyze = analyze
    }

    private var clips: [ClipListItem] { viewModel.clipsToName }

    var body: some View {
        Group {
            if clips.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("Clips")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbar }
        // Back, then add, as the bar reads from its leading item.
        .verticalBarColumn(verticalBar) {
            backButton
            ScrimIconButton(systemImage: "plus", accessibilityLabel: "Add clip", action: addClip)
                .accessibilityIdentifier("add-clip")
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationDestination(isPresented: $isNaming) {
            NameClipsView(
                viewModel: viewModel, startIndex: namingStart, vocabulary: vocabulary, account: account,
                outbox: outbox, popToRoot: popToRoot)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { proxy in
            let columns = ClipListLayout.columnCount(for: proxy.size.width)
            let side = ClipListLayout.tileSide(for: proxy.size.width, columns: columns)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(side), spacing: ClipListLayout.spacing, alignment: .top),
                            count: columns),
                        spacing: ClipListLayout.rowSpacing
                    ) {
                        ForEach(clips) { item in
                            tile(for: item, side: side)
                        }
                    }
                    .padding(.horizontal, ClipListLayout.inset)
                    .padding(.vertical, 8)
                    // The grid states its count when VoiceOver enters it: a run that found clips
                    // otherwise announces its result only as the screen changing. The grid must be
                    // an accessibility container for that label to be read on entry.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(ClipListAccessibility.gridLabel(clipCount: clips.count))
                    .accessibilityIdentifier("clip-grid")
                }
                .onChange(of: addedClipID) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { scroller.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func tile(for item: ClipListItem, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipCard(
                item: item, side: side, placement: .tile, viewModel: viewModel,
                // Paused, not playing, while Name Clips covers the grid.
                isPlaying: !isNaming,
                onOpen: { _, _, _ in openNaming(on: item) })
            // The card's own label already reads the length and the names.
            Text(caption(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: side, alignment: .leading)
                .accessibilityHidden(true)
        }
        .id(item.id)
    }

    /// "2.4s", then the names given, if any: "2.4s · cork, gainer".
    private func caption(for item: ClipListItem) -> String {
        guard !item.names.isEmpty else { return item.durationLabel }
        return item.durationLabel + " · " + item.names.map(\.name).joined(separator: ", ")
    }

    private func openNaming(on item: ClipListItem) {
        guard let start = clips.firstIndex(where: { $0.id == item.id }) else { return }
        openNaming(at: start)
    }

    private func openNaming(at start: Int) {
        namingStart = start
        isNaming = true
    }

    /// "+" and "Clip manually": a new clip over the first seconds of the video, which the editor
    /// trims; the grid scrolls to its tile.
    private func addClip() {
        Task {
            await viewModel.addClip()
            addedClipID = clips.last?.id
        }
    }

    // MARK: - Chrome

    /// None on iPhone Duo, where the items go down the vertical bar (`verticalBarColumn`).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if verticalBar == nil {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarLeading) { backButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { addButton }
            } else {
                ToolbarItem(placement: .navigationBarLeading) { backButton }
                ToolbarItem(placement: .topBarTrailing) { addButton }
            }
        }
    }

    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to Home", action: popToRoot)
            .accessibilityIdentifier("clip-list-back")
    }

    private var addButton: some View {
        Button(action: addClip) {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add clip")
        .accessibilityIdentifier("add-clip")
    }

    @ViewBuilder
    private var actionBar: some View {
        if clips.isEmpty {
            if let analyze {
                PrimaryActionBar("Analyze clips", secondary: .init("Clip manually", action: addClip), action: analyze)
                    .accessibilityIdentifier("start-analysis")
            } else {
                PrimaryActionBar("Clip manually", action: addClip)
                    .accessibilityIdentifier("clip-list-clip-manually")
            }
        } else {
            PrimaryActionBar("Name clips") { openNaming(at: 0) }
                .accessibilityIdentifier("clip-list-name-clips")
        }
    }

    /// What an analysis that left no clip shows: that it found nothing, or — for a video reached
    /// by "Clip it", or one whose clips were all removed — that there is nothing yet, over the
    /// bar's "Analyze clips" and "Clip manually".
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(showsNoTricksFound ? ClipListAccessibility.noTricksFound : String(localized: "No clips yet"))
                .font(.headline)
                .accessibilityIdentifier("no-tricks-notice")
            Text("Add a clip, then trim it to the trick in the editor.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if showsNoTricksFound { viewModel.announceNoTricksFound() } }
    }
}

/// How Clip List lays its tiles out: two across an iPhone held upright, and on a wider screen as
/// many as keep each tile at least `minimumTileSide` across.
enum ClipListLayout {
    static let inset: CGFloat = 16
    static let spacing: CGFloat = 12
    /// Room for the caption under a row of tiles, as well as the gap.
    static let rowSpacing: CGFloat = 16
    static let minimumTileSide: CGFloat = 160

    /// How many tiles fit across a grid `width` points wide.
    static func columnCount(for width: CGFloat) -> Int {
        let room = width - 2 * inset + spacing
        return max(2, Int(room / (minimumTileSide + spacing)))
    }

    /// The side of each of `columns` tiles across `width`, whole points.
    static func tileSide(for width: CGFloat, columns: Int) -> CGFloat {
        let room = width - 2 * inset - CGFloat(columns - 1) * spacing
        return max(floor(room / CGFloat(columns)), 0)
    }
}

#Preview {
    NavigationStack {
        ClipListView(
            items: [
                ClipListItem(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                ClipListItem(
                    window: TrickWindow(startTime: 9, endTime: 11.5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
            ],
            // AVAsset is abstract; the URL resolves to nothing, so the tiles show their placeholder.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "preview",
            duration: 15)
    }
    .preferredColorScheme(.dark)
}
