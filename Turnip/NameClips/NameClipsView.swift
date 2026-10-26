import SwiftUI

/// Name Clips (`docs/UIUX.md` § "Name Clips", `docs/PROFILE_DESIGN.md` §4): one clip at a time,
/// looping with the framing it exports with, and under it the trick-name field, the names given
/// as removable chips, suggestions, who is in the clip, and — when the build points at a farm —
/// the clip's contribute toggle. Naming is never required: "Skip" moves on, "Save now" saves at
/// once.
///
/// Pushed from Clip List onto the same stack, writing names straight onto Clip List's items, so
/// the chevron back keeps every name given. The pager owns every horizontal drag, as Processing's
/// browse swipe does, and "Next" plays the same slide.
struct NameClipsView: View {
    @ObservedObject var viewModel: ClipListViewModel
    @ObservedObject var vocabulary: VocabularyStore
    @ObservedObject var account: FarmAccount
    let popToRoot: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var dragOffset: CGFloat = 0
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool
    @State private var contribution: ContributionPlan?
    @State private var isShowingContribution = false

    private static let slide: Animation = .easeInOut(duration: 0.3)

    init(
        viewModel: ClipListViewModel, vocabulary: VocabularyStore = .shared, account: FarmAccount = .shared,
        popToRoot: @escaping () -> Void
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _vocabulary = ObservedObject(wrappedValue: vocabulary)
        _account = ObservedObject(wrappedValue: account)
        self.popToRoot = popToRoot
    }

    private var clips: [ClipListItem] { viewModel.clipsToName }
    private var isLast: Bool { index >= clips.count - 1 }

    var body: some View {
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
            .contentShape(Rectangle())
            // Simultaneous, so the switch and the segmented control under it still take their taps.
            .simultaneousGesture(pagingGesture(width: proxy.size.width))
        }
        .clipped()
        .disabled(viewModel.isSaving)
        .navigationTitle(String(localized: "\(min(index + 1, clips.count)) of \(clips.count)"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarLeading) { backButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigationBarLeading) { backButton }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .overlay { if viewModel.isSaving { SavingOverlay() } }
        .errorAlert("Couldn't save clips", message: $viewModel.saveFailureMessage)
        .sheet(isPresented: $isShowingContribution, onDismiss: popToRoot) {
            if let contribution {
                ContributionSheet(
                    model: ContributionViewModel(plan: contribution, account: account),
                    thumbnail: { await viewModel.thumbnail(for: $0) })
            }
        }
        .task { await vocabulary.refreshIfStale() }
    }

    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to clips") {
            commitDraft()
            dismiss()
        }
        .disabled(viewModel.isSaving)
        .accessibilityIdentifier("name-clips-back")
    }

    private func page(for item: ClipListItem, isCurrent: Bool) -> some View {
        NameClipPage(
            item: item,
            viewModel: viewModel,
            vocabulary: vocabulary.current,
            showsContribution: account.isAvailable,
            draft: isCurrent ? $draft : .constant(""),
            isFieldFocused: $isFieldFocused,
            isCurrent: isCurrent,
            commitDraft: commitDraft)
    }

    private var actionBar: some View {
        let hasName = clips.indices.contains(index) && !(clips[index].names.isEmpty && draft.isBlank)
        let title = isLast
            ? String(localized: "Save Clips")
            : hasName ? String(localized: "Next") : String(localized: "Skip")
        let secondary = isLast || isFieldFocused
            ? nil
            : PrimaryActionBar.SecondaryAction(String(localized: "Save now"), action: save)
        return PrimaryActionBar(title, isEnabled: !viewModel.isSaving, secondary: secondary) {
            if isLast { save() } else { go(to: index + 1) }
        }
        .accessibilityIdentifier("name-clips-primary")
    }

    private func pagingGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                dragOffset = BrowseSwipe.pageOffset(
                    translation: value.translation.width, hasPrevious: index > 0, hasNext: !isLast)
            }
            .onEnded { value in
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

    /// The one entry point the swipe and the button share: commits what is typed to the clip
    /// being left, then slides to `target`.
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

    /// Clip List's save, then the contribution sheet when any saved clip was toggled on and the
    /// farm can take it, and back to Home once that closes.
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

/// One clip's page: its loop on top, the naming controls under it.
private struct NameClipPage: View {
    let item: ClipListItem
    @ObservedObject var viewModel: ClipListViewModel
    let vocabulary: TrickVocabulary
    let showsContribution: Bool
    @Binding var draft: String
    var isFieldFocused: FocusState<Bool>.Binding
    let isCurrent: Bool
    let commitDraft: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            NameClipPlayer(item: item, viewModel: viewModel, isPlaying: isCurrent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)
            VStack(alignment: .leading, spacing: 12) {
                nameChips
                correction
                nameField
                suggestionChips
                whoIsIn
                if showsContribution { contributeToggle }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var nameChips: some View {
        if !item.names.isEmpty {
            ChipFlow {
                ForEach(item.names, id: \.self) { name in
                    Button {
                        viewModel.removeName(name, from: item.id)
                    } label: {
                        Label(name.name, systemImage: "xmark")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(ChipButtonStyle(isProminent: true))
                    .accessibilityLabel(name.name)
                    .accessibilityHint("Removes this name")
                }
            }
            .accessibilityIdentifier("name-clips-names")
        }
    }

    /// "Did you mean": for the newest typed name that is a near miss of a vocabulary name.
    @ViewBuilder
    private var correction: some View {
        if let typed = item.names.last(where: { $0.origin == .typed }),
           let canonical = vocabulary.suggestedCorrection(for: typed.name),
           TrickVocabulary.normalized(canonical) != TrickVocabulary.normalized(typed.name) {
            Button {
                viewModel.replaceName(typed, with: canonical, in: item.id)
            } label: {
                Text("Did you mean **\(canonical)**?")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("name-clips-did-you-mean")
        }
    }

    private var nameField: some View {
        TextField("What trick is this? e.g. cork", text: $draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .focused(isFieldFocused)
            .disabled(!isCurrent)
            .onSubmit {
                commitDraft()
                // Return adds the name and keeps the keyboard up for the next one in a combo.
                if isCurrent { isFieldFocused.wrappedValue = true }
            }
            .accessibilityIdentifier("name-clips-field")
    }

    private var suggestionChips: some View {
        ChipFlow {
            ForEach(suggestions, id: \.self) { name in
                Button(name) {
                    // A pick from the vocabulary is `vocabulary`; a name used earlier on this video
                    // that the vocabulary doesn't know was typed, so it stays `typed`.
                    let origin: LabelOrigin = vocabulary.canonicalName(for: name) == nil ? .typed : .vocabulary
                    viewModel.addName(name, origin: origin, to: item.id)
                    draft = ""
                }
                .buttonStyle(ChipButtonStyle(isProminent: false))
            }
        }
        .accessibilityIdentifier("name-clips-suggestions")
    }

    /// Names used on this video first, then the vocabulary's matches for what is typed, led by
    /// a near-miss correction; none the clip already has.
    private var suggestions: [String] {
        let query = TrickVocabulary.normalized(draft)
        let used = viewModel.namesUsedOnVideo.filter { query.isEmpty || TrickVocabulary.normalized($0).contains(query) }
        let corrected = vocabulary.suggestedCorrection(for: draft).map { [$0] } ?? []
        var seen = Set(item.names.map { TrickVocabulary.normalized($0.name) })
        return (used + corrected + vocabulary.names(matching: query))
            .filter { seen.insert(TrickVocabulary.normalized($0)).inserted }
            .prefix(8)
            .map { $0 }
    }

    private var whoIsIn: some View {
        Picker("Who's in it", selection: Binding(
            get: { item.isMe },
            set: { viewModel.setIsMe($0, for: item.id) })
        ) {
            Text("Me").tag(true)
            Text("Someone else").tag(false)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("name-clips-who")
    }

    private var contributeToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Contribute this clip", isOn: Binding(
                get: { item.contributes },
                set: { viewModel.setContributes($0, for: item.id) }))
                .disabled(item.names.isEmpty || !viewModel.hasPose)
                .accessibilityIdentifier("name-clips-contribute")
            if !viewModel.hasPose {
                Text("Clips added without analysis have no pose to contribute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if item.names.isEmpty {
                Text("Name the clip to contribute it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The page's clip, looping its window with the framing export uses — its Clip List tile's
/// picture, larger — through the same `ClipCardPlayback` the tile drives.
private struct NameClipPlayer: View {
    let item: ClipListItem
    @ObservedObject var viewModel: ClipListViewModel
    let isPlaying: Bool
    @StateObject private var playback: ClipCardPlayback
    @State private var thumbnail: CGImage?
    @State private var isLoopReady = false

    init(item: ClipListItem, viewModel: ClipListViewModel, isPlaying: Bool) {
        self.item = item
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.isPlaying = isPlaying
        _playback = StateObject(wrappedValue: ClipCardPlayback(
            asset: viewModel.sourceAsset,
            loadComposition: { [viewModel] geometry in await viewModel.videoComposition(for: geometry) },
            loadDuration: { [viewModel] in await viewModel.assetDuration() }))
    }

    var body: some View {
        ZStack {
            if !isLoopReady, let thumbnail {
                Image(decorative: thumbnail, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else if !isLoopReady {
                Color(.quaternarySystemFill)
            }
            if let loop = playback.loop {
                BareVideoPlayerView(
                    player: loop.player, videoGravity: .resizeAspectFill, onReadyForDisplay: { isLoopReady = true })
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Clip, \(item.durationLabel)"))
        .task {
            playback.start(geometry: geometry, isSuspended: !isPlaying)
            thumbnail = await viewModel.thumbnail(for: item)
        }
        .onChange(of: isPlaying) { playback.setSuspended(!$0) }
        .onChange(of: playback.loop.map { ObjectIdentifier($0.player) }) { _ in isLoopReady = false }
        .onDisappear { playback.teardown() }
    }

    private var geometry: ClipCardPlaybackGeometry {
        ClipCardPlaybackGeometry(
            window: item.window, cropRect: item.cropRect, cropAdjustment: item.cropAdjustment,
            framingMode: item.framingMode, followCrop: item.followCrop, personID: item.personID)
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
