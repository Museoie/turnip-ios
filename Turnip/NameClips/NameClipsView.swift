import AVFoundation
import SwiftUI

/// Name Clips (`docs/UIUX.md` § "Name Clips", `docs/PROFILE_DESIGN.md` §4): Clip List
/// (`ClipListView`) pushes this on the tile it was tapped from. One clip at a time, looping with
/// the framing it exports with, and under it the trick-name field, the names given as chips,
/// suggestions, and who is in the clip. Naming is never required: "Previous" and "Next" step
/// through the clips, and the last clip's "Save Clips" saves them all at once.
///
/// Tapping the card flies it open into the editor (`ClipExpansionContainer`), the header's "+"
/// adds a clip, and the header's menu removes the one on screen; removing the last clip goes back
/// to the list, which says there are none. Every change is to the list's own `ClipListViewModel`,
/// so the grid shows it on the way back.
///
/// The pager owns every horizontal drag that starts above the bottom bar (the bar sits outside
/// it, so a swipe that starts there doesn't page), and holds the page's own vertical scroll
/// still while it slides. The back chevron pops to the list; a save pops to Home (`popToRoot`).
/// This view declares no `NavigationStack` of its own.
struct NameClipsView: View {
    @ObservedObject private var viewModel: ClipListViewModel
    @ObservedObject private var vocabulary: VocabularyStore
    @ObservedObject private var account: FarmAccount
    private let outbox: ContributionOutbox
    let popToRoot: () -> Void

    @State private var index: Int
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
    /// iPhone Duo's vertical bar, which the bar's items go down instead.
    @Environment(\.verticalBar) private var verticalBar
    /// Pops back to the list.
    @Environment(\.dismiss) private var dismiss

    private static let slide: Animation = .easeInOut(duration: 0.3)

    /// `startIndex` is the clip the list's tile was tapped on, among `viewModel.clipsToName`.
    init(
        viewModel: ClipListViewModel,
        startIndex: Int = 0,
        vocabulary: VocabularyStore = .shared,
        account: FarmAccount = .shared,
        outbox: ContributionOutbox = .shared,
        popToRoot: @escaping () -> Void = {}
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _index = State(initialValue: startIndex)
        _vocabulary = ObservedObject(wrappedValue: vocabulary)
        _account = ObservedObject(wrappedValue: account)
        self.outbox = outbox
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
                // Only for as long as the pop back to the list takes, once the last clip is removed.
                Color.clear
            } else {
                pager
            }
        }
        // The card's size is worked out from this measurement of the page above the bottom bar,
        // which ignores the keyboard and holds still while the name field has focus
        // (`NameClipsLayout.acceptsMeasurement`): the keyboard scrolls the page instead of
        // resizing the card.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { screenSize = proxy.size }
                    .onChange(of: proxy.size) { size in
                        if NameClipsLayout.acceptsMeasurement(size, over: screenSize, isTyping: isFieldFocused) {
                            screenSize = size
                        }
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
        // Back, add, then the menu, as the bar reads from its leading item.
        .verticalBarColumn(verticalBar) {
            backButton
            ScrimIconButton(systemImage: "plus", accessibilityLabel: "Add clip", action: addClip)
                .accessibilityIdentifier("add-clip")
            if !clips.isEmpty {
                menu(label: ScrimIconGlyph(systemImage: "ellipsis"))
            }
        }
        // The keyboard is up while the name field has focus: the bar gives its room to the
        // naming controls, and comes back once the keyboard goes.
        .safeAreaInset(edge: .bottom) {
            if !isFieldFocused { actionBar }
        }
        .overlay { if viewModel.isSaving { SavingOverlay() } }
        .errorAlert("Couldn't save clips", message: $viewModel.saveFailureMessage)
        .fullScreenCover(item: $expandTarget, onDismiss: { hiddenItemID = nil }, content: editor(for:))
        .sheet(isPresented: $isShowingContribution, onDismiss: popToRoot) {
            if let contribution {
                ContributionSheet(
                    plan: contribution,
                    account: account,
                    thumbnail: { await viewModel.thumbnail(for: $0) },
                    confirm: { source in Task { await outbox.confirm(source) } })
            }
        }
        .onChange(of: clips.count) { count in
            // With no clip left there is nothing to name: the list says so instead.
            guard count > 0 else {
                dismiss()
                return
            }
            // A discarded last clip leaves its neighbour current, sliding in from the side.
            if index >= count { withAnimation(Self.slide) { index = count - 1 } }
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

    /// Where a swipe lands, and the bar's Previous / Next and the card's Previous clip / Next
    /// clip: commits what is typed to the clip being left, then slides to `target`.
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

    /// None on iPhone Duo, where the items go down the vertical bar (`verticalBarColumn`).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if verticalBar == nil {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarLeading) { backButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { addButton }
                if !clips.isEmpty {
                    // Two circles rather than one shared capsule.
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) { menu(label: moreGlyph) }
                }
            } else {
                ToolbarItem(placement: .navigationBarLeading) { backButton }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        addButton
                        if !clips.isEmpty { menu(label: moreGlyph) }
                    }
                }
            }
        }
    }

    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to all clips") {
            commitDraft()
            dismiss()
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

    /// The bar's own glyph, which the bar styles.
    private var moreGlyph: some View {
        Image(systemName: "ellipsis")
    }

    private func menu<MenuLabel: View>(label: MenuLabel) -> some View {
        Menu {
            Button(role: .destructive, action: removeCurrentClip) {
                Label("Remove this clip", systemImage: "trash")
            }
            .accessibilityIdentifier("remove-clip")
        } label: {
            label
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("name-clips-more")
    }

    @ViewBuilder
    private var actionBar: some View {
        if !clips.isEmpty { pagingBar }
    }

    /// Previous in the leading corner and Next in the trailing one, playing the swipe's slide.
    /// The first clip has no Previous; the last clip's trailing button is "Save Clips" instead.
    /// The trailing button holds its corner whether or not Previous is there.
    private var pagingBar: some View {
        HStack(spacing: 12) {
            if index > 0 {
                Button { go(to: index - 1) } label: {
                    Text("Previous").frame(minWidth: 88)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("name-clips-previous")
            }
            Spacer(minLength: 0)
            if isLast {
                Button(action: save) {
                    Text("Save Clips").frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSaving)
                .accessibilityValue(saveAccessibilityValue)
                .accessibilityIdentifier("name-clips-save")
            } else {
                Button { go(to: index + 1) } label: {
                    Text("Next").frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("name-clips-next")
            }
        }
        .controlSize(.large)
        .padding()
        .background(.thinMaterial)
    }

    /// What Save Clips commits to, read after its label: how many clips it writes.
    private var saveAccessibilityValue: String {
        ClipListAccessibility.saveClipsValue(clipCount: viewModel.unsavedClipCount)
    }

    // MARK: - Save

    /// The save, then back to Home, by way of the contribution sheet when it asks first
    /// (`ClipListViewModel.saveClips`).
    private func save() {
        commitDraft()
        isFieldFocused = false
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
        NameClipsView(viewModel: ClipListViewModel(
            items: [
                ClipListItem(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
            ],
            // AVAsset is abstract; the URL resolves to nothing, so the card shows its placeholder.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "preview",
            duration: 15))
    }
    .preferredColorScheme(.dark)
}
