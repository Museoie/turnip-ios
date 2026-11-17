import AVFoundation
import SwiftUI

/// Clip List (`docs/UIUX.md` § "Clip List"): where an analysis lands, where Processing's "Clip it"
/// goes, and where a camera take live inference fully covered lands. A grid with a tile per clip
/// (`ClipCard`), each looping its window with the framing it exports with, carrying the timeline of
/// where it sits in the video, over its length and the names it has been given as chips.
///
/// Tapping a tile pushes Name Clips (`NameClipsView`) on that clip, which pages through the rest
/// from there. Both screens work on this screen's `ClipListViewModel`, so a name, an edit, a clip
/// added or removed there is on the grid on the way back.
///
/// "Save Clips" saves every clip, as Name Clips' does on its last clip. "Select" turns the grid into
/// a selection, as Photos does: a tile tap marks or unmarks it, the back chevron and "+" stand down
/// until "Cancel", and a bar along the bottom deletes the marked clips together. With no clip, the
/// screen offers "Analyze clips" (`analyze`) and "Clip manually". The back chevron pops to Home.
/// This view declares no `NavigationStack` of its own.
///
/// The filter button opens `ClipFilterSheet`, which hides clips by detection's confidence and by
/// the colour of the top their person wears (`ClipFilter`). A hidden clip is left off the grid,
/// Name Clips and Save Clips; a line over the grid says how many show, with "Clear" beside it.
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
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var isConfirmingDelete = false
    @State private var contribution: ContributionPlan?
    @State private var isShowingContribution = false
    @State private var isFiltering = false
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

    /// The marked clips still on the grid, in grid order.
    private var selectedIDs: [UUID] { clips.map(\.id).filter(selection.contains) }

    private var title: String {
        guard isSelecting else { return String(localized: "Clips") }
        return selectedIDs.isEmpty
            ? String(localized: "Select Clips") : String(localized: "\(selectedIDs.count) Selected")
    }

    var body: some View {
        Group {
            if !clips.isEmpty {
                grid
            } else if viewModel.allClips.isEmpty {
                emptyState
            } else {
                filteredEmptyState
            }
        }
        .disabled(viewModel.isSaving)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbar }
        // Back, add, the filter, then Select, as the bar reads from its leading item.
        .verticalBarColumn(verticalBar) {
            if !isSelecting {
                backButton
                ScrimIconButton(systemImage: "plus", accessibilityLabel: "Add clip", action: addClip)
                    .disabled(viewModel.isSaving)
                    .accessibilityIdentifier("add-clip")
                if offersFilter {
                    ScrimIconButton(systemImage: filterGlyph, accessibilityLabel: "Filter", action: openFilter)
                        .disabled(viewModel.isSaving)
                        .accessibilityValue(ClipListAccessibility.filterState(isActive: viewModel.filter.isActive))
                        .accessibilityIdentifier("clip-list-filter")
                }
            }
            if !clips.isEmpty {
                // A glyph here, as the column is too narrow for the bar's words at larger text.
                ScrimIconButton(
                    systemImage: isSelecting ? "xmark" : "checkmark.circle",
                    accessibilityLabel: isSelecting ? "Cancel" : "Select",
                    action: toggleSelecting)
                .disabled(viewModel.isSaving)
                .accessibilityIdentifier("clip-list-select")
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .overlay { if viewModel.isSaving { SavingOverlay() } }
        // Name Clips, pushed over the grid, puts up the failure of a save it started itself.
        .errorAlert(
            "Couldn't save clips",
            message: isNaming ? Binding<String?>.constant(nil) : $viewModel.saveFailureMessage)
        .sheet(isPresented: $isShowingContribution, onDismiss: popToRoot) { contributionSheet }
        .sheet(isPresented: $isFiltering) { ClipFilterSheet(viewModel: viewModel) }
        .confirmationDialog(
            ClipListAccessibility.deleteClips(count: selectedIDs.count),
            isPresented: $isConfirmingDelete, titleVisibility: .hidden
        ) {
            Button(
                ClipListAccessibility.deleteClips(count: selectedIDs.count), role: .destructive,
                action: deleteSelected)
        }
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
                    .accessibilityLabel(gridLabel)
                    .accessibilityIdentifier("clip-grid")
                }
                .onChange(of: addedClipID) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { scroller.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if viewModel.filter.isActive && !isSelecting { filterStatus }
        }
    }

    /// What the filters leave, over the grid while one is on, with the way to turn them off.
    private var filterStatus: some View {
        HStack(spacing: 12) {
            Text(ClipListAccessibility.shownClips(shown: clips.count, total: viewModel.allClips.count))
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Button("Clear", action: clearFilter)
                .font(.subheadline)
                .disabled(viewModel.isSaving)
                .accessibilityIdentifier("clip-list-clear-filter")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// One card whichever the mode, so a tile keeps its loop as the grid goes in and out of
    /// selecting.
    private func tile(for item: ClipListItem, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipCard(
                item: item, side: side, placement: .tile, viewModel: viewModel,
                // Paused, not playing, under Name Clips, a save and either sheet: the filter sheet
                // decodes frames to read shirt colours.
                isPlaying: !isNaming && !viewModel.isSaving && !isShowingContribution && !isFiltering,
                selection: isSelecting ? selection.contains(item.id) : nil,
                onOpen: { _, _, _ in tapped(item) })
            ClipTileCaption(item: item, width: side)
        }
        .id(item.id)
    }

    /// A tile's tap: Name Clips on its clip, or, while selecting, a mark on or off it.
    private func tapped(_ item: ClipListItem) {
        guard isSelecting else {
            openNaming(on: item)
            return
        }
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    private func openNaming(on item: ClipListItem) {
        guard let start = clips.firstIndex(where: { $0.id == item.id }) else { return }
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

    // MARK: - Selecting

    private func toggleSelecting() {
        isSelecting.toggle()
        selection = []
    }

    // MARK: - Filters

    /// The filter button shows once detection has proposed a clip, which is what the filters hide.
    private var offersFilter: Bool { !viewModel.filterableClips.isEmpty }

    /// Filled while a filter is on, as Home's gallery filter is, so a grid of what is left reads as
    /// filtered and not as all there is.
    private var filterGlyph: String {
        viewModel.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    private func openFilter() {
        isFiltering = true
    }

    private func clearFilter() {
        withAnimation(.easeInOut(duration: 0.3)) { viewModel.clearFilter() }
    }

    /// The grid's count on entry, with how many there are when a filter hides some.
    private var gridLabel: String {
        viewModel.filter.isActive
            ? ClipListAccessibility.shownClips(shown: clips.count, total: viewModel.allClips.count)
            : ClipListAccessibility.gridLabel(clipCount: clips.count)
    }

    /// Removes every marked clip at once, as Name Clips' "Remove this clip" removes one, and leaves
    /// selecting. A clip already in Photos stays there, as it does from Name Clips.
    private func deleteSelected() {
        let removed = selectedIDs
        withAnimation(.easeInOut(duration: 0.3)) {
            for id in removed {
                viewModel.delete(id)
            }
        }
        isSelecting = false
        selection = []
    }

    // MARK: - Chrome

    /// None on iPhone Duo, where the items go down the vertical bar (`verticalBarColumn`). While
    /// selecting, the back chevron, the filter button and "+" stand down: "Cancel" is the way out of
    /// a selection.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if verticalBar == nil {
            if #available(iOS 26.0, *) {
                if !isSelecting {
                    ToolbarItem(placement: .navigationBarLeading) { backButton }
                        .sharedBackgroundVisibility(.hidden)
                    if offersFilter {
                        ToolbarItem(placement: .topBarTrailing) { filterButton }
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    ToolbarItem(placement: .topBarTrailing) { addButton }
                }
                if !clips.isEmpty {
                    if !isSelecting {
                        // "+" and Select as two pieces of glass rather than one shared capsule.
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    ToolbarItem(placement: .topBarTrailing) { selectButton }
                }
            } else {
                if !isSelecting {
                    ToolbarItem(placement: .navigationBarLeading) { backButton }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if !isSelecting {
                            if offersFilter { filterButton }
                            addButton
                        }
                        if !clips.isEmpty { selectButton }
                    }
                }
            }
        }
    }

    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to Home", action: popToRoot)
            .disabled(viewModel.isSaving)
            .accessibilityIdentifier("clip-list-back")
    }

    /// Off during a save, like every header control: the bar sits outside the content the save
    /// disables, and a clip added mid-save would be left out of it without a word.
    private var addButton: some View {
        Button(action: addClip) {
            Image(systemName: "plus")
        }
        .disabled(viewModel.isSaving)
        .accessibilityLabel("Add clip")
        .accessibilityIdentifier("add-clip")
    }

    private var filterButton: some View {
        Button(action: openFilter) {
            Image(systemName: filterGlyph)
        }
        .disabled(viewModel.isSaving)
        .accessibilityLabel("Filter")
        .accessibilityValue(ClipListAccessibility.filterState(isActive: viewModel.filter.isActive))
        .accessibilityIdentifier("clip-list-filter")
    }

    private var selectButton: some View {
        Button(action: toggleSelecting) {
            Text(isSelecting ? "Cancel" : "Select")
        }
        .disabled(viewModel.isSaving)
        .accessibilityIdentifier("clip-list-select")
    }

    @ViewBuilder
    private var actionBar: some View {
        if isSelecting {
            deleteBar
        } else if clips.isEmpty {
            if !viewModel.allClips.isEmpty {
                // Every clip is filtered out: the empty state offers Clear Filters instead.
                EmptyView()
            } else if let analyze {
                PrimaryActionBar("Analyze clips", secondary: .init("Clip manually", action: addClip), action: analyze)
                    .accessibilityIdentifier("start-analysis")
            } else {
                PrimaryActionBar("Clip manually", action: addClip)
                    .accessibilityIdentifier("clip-list-clip-manually")
            }
        } else {
            PrimaryActionBar("Save Clips", isEnabled: !viewModel.isSaving, action: save)
                // What the tap commits to, read after the label: how many clips it writes.
                .accessibilityValue(ClipListAccessibility.saveClipsValue(clipCount: viewModel.unsavedClipCount))
                .accessibilityIdentifier("clip-list-save")
        }
    }

    /// The selection's one action, asking first: the marked clips go with no restore.
    private var deleteBar: some View {
        let count = selectedIDs.count
        return Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Label(
                count == 0 ? String(localized: "Delete") : ClipListAccessibility.deleteClips(count: count),
                systemImage: "trash")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(count == 0)
        .padding()
        .background(.thinMaterial)
        .accessibilityIdentifier("clip-list-delete")
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

    /// What a filter hiding every clip shows, so it doesn't read as a video with no clips.
    private var filteredEmptyState: some View {
        StatusStateView(
            systemImage: "line.3.horizontal.decrease.circle",
            title: "No matches",
            message: "No clips match the filters."
        ) {
            Button("Clear Filters", action: clearFilter)
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
                .accessibilityIdentifier("clip-list-clear-filters")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Save

    /// The save, then back to Home, by way of the contribution sheet when it asks first
    /// (`ClipListViewModel.saveClips`).
    private func save() {
        Task {
            switch await viewModel.saveClips(account: account, outbox: outbox) {
            case .failed:
                break
            case .finished:
                popToRoot()
            case .asksToContribute(let plan):
                contribution = plan
                isShowingContribution = true
            }
        }
    }

    @ViewBuilder
    private var contributionSheet: some View {
        if let contribution {
            ContributionSheet(
                plan: contribution,
                account: account,
                thumbnail: { await viewModel.thumbnail(for: $0) },
                confirm: { source in Task { await outbox.confirm(source) } })
        }
    }
}

/// A tile's caption: the clip's length, then each name it has been given as a chip in Name Clips'
/// style (`ChipButtonStyle`, prominent), cut down to the length's own size, all on one line
/// (`ChipLine`): names that don't fit beside the length are cut short with an ellipsis. VoiceOver
/// skips it: the card's label reads the length and every name.
private struct ClipTileCaption: View {
    let item: ClipListItem
    let width: CGFloat

    /// The chips' padding above and below their text, given to the length too, so the two sit on
    /// one line at one height.
    private static let verticalPadding: CGFloat = 1
    /// `ChipLine.minimumCutWidth` at the chips' text size: a cut chip keeps room for a letter and
    /// the ellipsis however large the text is set.
    @ScaledMetric(relativeTo: .caption) private var minimumCutWidth: CGFloat = 32

    var body: some View {
        HStack(spacing: 4) {
            Text(item.durationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, Self.verticalPadding)
                .fixedSize()
            ChipLine(spacing: 4, minimumCutWidth: minimumCutWidth) {
                ForEach(item.names, id: \.self) { name in
                    Text(name.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.vertical, Self.verticalPadding)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            // The names left out sit just past the line's end.
            .clipped()
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
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
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
                    names: [ClipName(name: "cork", origin: .typed), ClipName(name: "gainer", origin: .typed)]),
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
