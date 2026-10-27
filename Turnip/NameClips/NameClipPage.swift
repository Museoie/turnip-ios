import SwiftUI

/// The size of Name Clips' card, worked out once from the screen and never from the page's
/// content, so a swipe, a name added, a "did you mean" line or the keyboard can't move it.
enum NameClipsLayout {
    static let horizontalInset: CGFloat = 16
    /// Room kept under the card for the naming controls before the card gives up height: the
    /// field, a row of suggestions, who's in it, and the contribute toggle. More controls than
    /// that scroll rather than shrink the card.
    static let controlsReserve: CGFloat = 240
    static let minimumSide: CGFloat = 220

    /// The card's side for a page `size` points large, measured without the keyboard: the
    /// width less its insets, unless that leaves less than `controlsReserve` below it.
    static func cardSide(for size: CGSize) -> CGFloat {
        let byWidth = size.width - 2 * horizontalInset
        let byHeight = size.height - controlsReserve
        return max(min(byWidth, byHeight), min(minimumSide, byWidth))
    }
}

/// One clip's page on Name Clips: its card on top at the screen's fixed size, and under it the
/// trick-name field, the names given as removable chips, suggestions, who is in the clip, and —
/// when the build points at a farm — the clip's contribute toggle. The page scrolls, so the
/// keyboard moves the controls into view instead of squeezing the card.
struct NameClipPage: View {
    let item: ClipListItem
    let cardSide: CGFloat
    @ObservedObject var viewModel: ClipListViewModel
    let vocabulary: TrickVocabulary
    let showsContribution: Bool
    @Binding var draft: String
    var isFieldFocused: FocusState<Bool>.Binding
    let isCurrent: Bool
    let isCardPlaying: Bool
    let isCardHidden: Bool
    let commitDraft: () -> Void
    let openEditor: (CGRect, CGImage?, TimeInterval?) -> Void
    let trash: () -> Void

    private static let suggestionsID = "suggestions"

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    NameClipCard(
                        item: item, side: cardSide, viewModel: viewModel, isPlaying: isCardPlaying,
                        isHidden: isCardHidden, onOpen: openEditor, onTrash: trash)
                    VStack(alignment: .leading, spacing: 12) {
                        nameChips
                        correction
                        nameField
                        suggestionChips.id(Self.suggestionsID)
                        whoIsIn
                        if showsContribution { contributeToggle }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, NameClipsLayout.horizontalInset)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isFieldFocused.wrappedValue) { focused in
                guard focused, isCurrent else { return }
                // After the keyboard's own animation has moved the page's bottom edge up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(Self.suggestionsID, anchor: .bottom) }
                }
            }
            // A name added while typing grows the chips above the field; the suggestions stay in view.
            .onChange(of: item.names.count) { _ in
                guard isFieldFocused.wrappedValue, isCurrent else { return }
                withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(Self.suggestionsID, anchor: .bottom) }
            }
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
