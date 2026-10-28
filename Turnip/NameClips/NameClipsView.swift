import AVFoundation
import SwiftUI

/// Name Clips (`docs/UIUX.md` § "Name Clips", `docs/PROFILE_DESIGN.md` §4): where an analysis
/// lands. One detected clip at a time, looping with the framing it exports with, and under it the
/// trick-name field, the names given as chips, suggestions, and who is in the clip. Naming is
/// never required: "Save Clips", on every clip, saves them all at once.
///
/// It is also the triage the clip grid used to be: tapping the card flies it open into the
/// editor (`ClipExpansionContainer`), the header's "+" adds a clip, and the header's menu
/// removes the one on screen.
///
/// The pager owns every horizontal drag, as Processing's browse swipe does, and holds the page's
/// own vertical scroll still while it slides. The processing screen pushes this with the
/// pipeline's output; the back chevron pops to Home. This view declares no `NavigationStack` of
/// its own.
struct NameClipsView: View {
    @StateObject private var viewModel: ClipListViewModel
    @ObservedObject private var vocabulary: VocabularyStore
    @ObservedObject private var account: FarmAccount
    /// A run that found nothing says so; a video that arrived by "Clip manually" wasn't looked at.
    let showsNoTricksFound: Bool
    let popToRoot: () -> Void

    @State private var index = 0
    @State private var dragOffset: CGFloat = 0
    /// The axis a drag committed to on its first movement: a vertical one scrolls the page and
    /// never pages, a horizontal one pages and stops the page's scroll (`NameClipPage.isPaging`).
    @State private var dragAxis: Axis?
    /// True from a drag's first movement until it ends or the system takes it (a call banner,
    /// Control Center). A taken drag never reaches `onEnded`, so its reset keys off this instead.
    @GestureState private var isDragging = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool
    @State private var screenSize: CGSize = .zero
    @State private var expandTarget: ExpandTarget?
    @State private var hiddenItemID: UUID?
    @State private var contribution: ContributionPlan?
    @State private var isShowingContribution = false

    private static let slide: Animation = .easeInOut(duration: 0.3)

    init(
        items: [ClipListItem],
        poseFrames: [PoseFrameResult] = [],
        people: [PoseTrack] = [],
        asset: AVAsset,
        assetIdentifier: String,
        duration: TimeInterval,
        loader: ClipThumbnailLoader = ClipThumbnailLoader(),
        showsNoTricksFound: Bool = false,
        vocabulary: VocabularyStore = .shared,
        account: FarmAccount = .shared,
        popToRoot: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: ClipListViewModel(
            items: items, poseFrames: poseFrames, people: people, asset: asset, assetIdentifier: assetIdentifier,
            duration: duration, loader: loader))
        _vocabulary = ObservedObject(wrappedValue: vocabulary)
        _account = ObservedObject(wrappedValue: account)
        self.showsNoTricksFound = showsNoTricksFound
        self.popToRoot = popToRoot
    }

    private var clips: [ClipListItem] { viewModel.clipsToName }
    private var title: String {
        clips.isEmpty ? String(localized: "Clips") : String(localized: "\(index + 1) of \(clips.count)")
    }
    private var isLast: Bool { index >= clips.count - 1 }
    private var cardSide: CGFloat { NameClipsLayout.cardSide(for: screenSize) }

    var body: some View {
        Group {
            if clips.isEmpty {
                emptyState
            } else {
                pager
            }
        }
        // The card's size is worked out from this measurement, which ignores the keyboard: the
        // keyboard scrolls the page instead of resizing the card.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { screenSize = proxy.size }
                    .onChange(of: proxy.size) { size in
                        if size.width != screenSize.width || screenSize == .zero { screenSize = size }
                    }
            }
            .ignoresSafeArea(.keyboard)
        }
        .disabled(viewModel.isSaving)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { actionBar }
        .overlay { if viewModel.isSaving { SavingOverlay() } }
        .errorAlert("Couldn't save clips", message: $viewModel.saveFailureMessage)
        .fullScreenCover(item: $expandTarget, onDismiss: { hiddenItemID = nil }, content: editor(for:))
        .sheet(isPresented: $isShowingContribution, onDismiss: popToRoot) {
            if let contribution {
                ContributionSheet(
                    model: ContributionViewModel(plan: contribution, account: account),
                    thumbnail: { await viewModel.thumbnail(for: $0) })
            }
        }
        .onChange(of: clips.count) { count in
            // A discarded last clip leaves its neighbour current, sliding in from the side.
            if index >= count { withAnimation(Self.slide) { index = max(count - 1, 0) } }
        }
        .task { await vocabulary.refreshIfStale() }
    }

    // MARK: - Pager

    private var pager: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(clips.enumerated()), id: \.element.id) { offset, item in
                    if abs(offset - index) <= 1 {
                        page(for: item, isCurrent: offset == index)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .offset(x: CGFloat(offset - index) * proxy.size.width + dragOffset)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .contentShape(Rectangle())
            // Simultaneous, so the controls and the page's own vertical scroll keep their touches.
            .simultaneousGesture(pagingGesture)
            .onChange(of: isDragging) { dragging in
                if !dragging { settleTakenDrag() }
            }
        }
        .clipped()
    }

    private func page(for item: ClipListItem, isCurrent: Bool) -> some View {
        NameClipPage(
            item: item,
            cardSide: cardSide,
            viewModel: viewModel,
            vocabulary: vocabulary.current,
            draft: isCurrent ? $draft : .constant(""),
            isFieldFocused: $isFieldFocused,
            isCurrent: isCurrent,
            isCardPlaying: isCurrent && expandTarget == nil && !viewModel.isSaving && !isShowingContribution,
            isCardHidden: hiddenItemID == item.id,
            isPaging: dragAxis == .horizontal,
            commitDraft: commitDraft,
            openEditor: { frame, thumbnail, loopTime in open(item, from: frame, thumbnail: thumbnail, at: loopTime) },
            goToPrevious: isCurrent && index > 0 ? { go(to: index - 1) } : nil,
            goToNext: isCurrent && !isLast ? { go(to: index + 1) } : nil)
    }

    private var pagingGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                dragOffset = BrowseSwipe.pageOffset(
                    translation: value.translation.width, hasPrevious: index > 0, hasNext: !isLast)
            }
            .onEnded { value in
                defer { dragAxis = nil }
                guard dragAxis == .horizontal else { return }
                let direction = BrowseSwipe.commit(
                    translation: value.translation.width,
                    predictedTranslation: value.predictedEndTranslation.width,
                    hasPrevious: index > 0, hasNext: !isLast)
                switch direction {
                case .next: go(to: index + 1)
                case .previous: go(to: index - 1)
                case nil: withAnimation(Self.slide) { dragOffset = 0 }
                }
            }
    }

    /// A drag the system took puts the page back and gives the page its scroll back. A no-op
    /// after an ordinary end, whose `onEnded` has already done both.
    private func settleTakenDrag() {
        guard dragAxis != nil else { return }
        dragAxis = nil
        withAnimation(Self.slide) { dragOffset = 0 }
    }

    /// Where a swipe lands, and the card's Previous clip / Next clip: commits what is typed to
    /// the clip being left, then slides to `target`.
    private func go(to target: Int) {
        guard clips.indices.contains(target) else { return }
        commitDraft()
        withAnimation(Self.slide) {
            index = target
            dragOffset = 0
        }
    }

    /// A name typed and left without pressing return still counts as given.
    private func commitDraft() {
        guard clips.indices.contains(index), !draft.isBlank else { return }
        viewModel.addName(draft, origin: .typed, to: clips[index].id)
        draft = ""
    }

    // MARK: - Triage

    /// The menu's "Remove this clip": discards the clip on screen outright; the clip after it
    /// slides into its place.
    private func removeCurrentClip() {
        guard clips.indices.contains(index) else { return }
        draft = ""
        withAnimation(Self.slide) { viewModel.delete(clips[index].id) }
    }

    /// "+": a new clip over the first seconds of the video, which the editor trims; the pager
    /// slides to it.
    private func addClip() {
        commitDraft()
        Task {
            await viewModel.addClip()
            withAnimation(Self.slide) {
                index = max(clips.count - 1, 0)
                dragOffset = 0
            }
        }
    }

    // MARK: - Editor

    private func open(_ item: ClipListItem, from frame: CGRect, thumbnail: CGImage?, at loopTime: TimeInterval?) {
        commitDraft()
        isFieldFocused = false
        SystemTransition.present {
            expandTarget = ExpandTarget(
                id: item.id, sourceFrame: frame,
                sourceTime: loopTime ?? (item.window.startTime + item.window.endTime) / 2,
                thumbnail: thumbnail, source: viewModel.editorSource(for: item))
        }
    }

    /// The card's destination: the full `ClipEditorView`, which `ClipExpansionContainer` flies open
    /// from the card's own frame and closes back into it.
    private func editor(for target: ExpandTarget) -> some View {
        let container = ClipExpansionContainer(
            sourceFrame: target.sourceFrame,
            sourceTime: target.sourceTime,
            thumbnail: target.thumbnail,
            source: target.source,
            onCommit: { result in viewModel.applyEditorResult(result, to: target.id) },
            onFlightStarted: { hiddenItemID = target.id }
        )
        // Lets this screen show through the cover while the card and scrim animate.
        return Group {
            if #available(iOS 16.4, *) {
                container.presentationBackground(.clear)
            } else {
                container
            }
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarLeading) { backButton }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { addButton }
            if !clips.isEmpty {
                // Two circles rather than one shared capsule.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
        } else {
            ToolbarItem(placement: .navigationBarLeading) { backButton }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    addButton
                    if !clips.isEmpty { menu }
                }
            }
        }
    }

    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to Home") {
            commitDraft()
            popToRoot()
        }
        .disabled(viewModel.isSaving)
        .accessibilityIdentifier("name-clips-back")
    }

    private var addButton: some View {
        Button(action: addClip) {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add clip")
        .accessibilityIdentifier("add-clip")
    }

    private var menu: some View {
        Menu {
            Button(role: .destructive, action: removeCurrentClip) {
                Label("Remove this clip", systemImage: "trash")
            }
            .accessibilityIdentifier("remove-clip")
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("name-clips-more")
    }

    @ViewBuilder
    private var actionBar: some View {
        if clips.isEmpty {
            PrimaryActionBar(String(localized: "Add Clip"), action: addClip)
                .accessibilityIdentifier("name-clips-primary")
        } else {
            PrimaryActionBar(String(localized: "Save Clips"), isEnabled: !viewModel.isSaving, action: save)
                .accessibilityValue(saveAccessibilityValue)
                .accessibilityIdentifier("name-clips-primary")
        }
    }

    /// What Save Clips commits to, read after its label: the count, and the original's fate.
    private var saveAccessibilityValue: String {
        let scope = viewModel.saveScope
        return ClipListAccessibility.saveClipsValue(clipCount: scope.clipCount, deletesOriginal: scope.deletesOriginal)
    }

    /// What an analysis that left no clip shows: that it found nothing, or — for a video reached
    /// by "Clip manually" — that there is nothing yet, and "Add Clip" below.
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

    // MARK: - Save

    /// The save, then the contribution sheet when Settings' Contribute named clips is on, a saved
    /// clip has a name and the farm can take it, and back to Home once that closes.
    private func save() {
        commitDraft()
        isFieldFocused = false
        Task {
            guard await viewModel.save() else { return }
            let plan = viewModel.contributionPlan()
            if account.isAvailable, plan.hasClips {
                contribution = plan
                isShowingContribution = true
            } else {
                popToRoot()
            }
        }
    }
}

/// The tapped card's presentation target, snapshotted at tap time: the editor's commit replaces
/// the item before the container's own close animation finishes.
private struct ExpandTarget: Identifiable {
    let id: UUID
    let sourceFrame: CGRect
    /// The frame the card was showing at the tap, in asset time — see
    /// `ClipExpansionContainer.sourceTime`.
    let sourceTime: TimeInterval
    let thumbnail: CGImage?
    let source: ClipEditorSource
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

#Preview {
    NavigationStack {
        NameClipsView(
            items: [
                ClipListItem(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
            ],
            // AVAsset is abstract; the URL resolves to nothing, so the card shows its placeholder.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "preview",
            duration: 15)
    }
    .preferredColorScheme(.dark)
}
