import SwiftUI

/// What the naming controls do to the clip they name: Name Clips' view model before the save, the
/// clip library after it.
struct ClipNamingActions {
    let add: (String, LabelOrigin) -> Void
    let remove: (ClipName) -> Void
    let replace: (ClipName, String) -> Void
    let setIsMe: (Bool) -> Void
}

/// Naming one clip (`docs/PROFILE_DESIGN.md` §4): the names given as removable chips, "Did you
/// mean", the trick-name field, suggestions, and who is in the clip. The same controls on Name
/// Clips, on the Profile's "Needs a name" and on its Clip view.
struct ClipNamingFields: View {
    /// The suggestions' scroll target, so a page can keep them above the keyboard.
    static let suggestionsID = "suggestions"

    let names: [ClipName]
    let isMe: Bool
    /// Names already given on this clip's video: the first suggestions.
    let usedNames: [String]
    let vocabulary: TrickVocabulary
    @Binding var draft: String
    var isFieldFocused: FocusState<Bool>.Binding
    /// False on a page beside the current one, whose field mustn't take focus.
    let isEnabled: Bool
    let commitDraft: () -> Void
    let actions: ClipNamingActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            nameChips
            correction
            nameField
            suggestionChips.id(Self.suggestionsID)
            whoIsIn
        }
    }

    @ViewBuilder
    private var nameChips: some View {
        if !names.isEmpty {
            ChipFlow {
                ForEach(names, id: \.self) { name in
                    Button {
                        actions.remove(name)
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
        if let typed = names.last(where: { $0.origin == .typed }),
           let canonical = vocabulary.suggestedCorrection(for: typed.name),
           TrickVocabulary.normalized(canonical) != TrickVocabulary.normalized(typed.name) {
            Button {
                actions.replace(typed, canonical)
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
            .disabled(!isEnabled)
            .onSubmit {
                commitDraft()
                // Return adds the name and keeps the keyboard up for the next one in a combo.
                if isEnabled { isFieldFocused.wrappedValue = true }
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
                    actions.add(name, origin)
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
        let used = usedNames.filter { query.isEmpty || TrickVocabulary.normalized($0).contains(query) }
        let corrected = vocabulary.suggestedCorrection(for: draft).map { [$0] } ?? []
        var seen = Set(names.map { TrickVocabulary.normalized($0.name) })
        return (used + corrected + vocabulary.names(matching: query))
            .filter { seen.insert(TrickVocabulary.normalized($0)).inserted }
            .prefix(8)
            .map { $0 }
    }

    private var whoIsIn: some View {
        Picker("Who's in it", selection: Binding(get: { isMe }, set: { actions.setIsMe($0) })) {
            Text("Me").tag(true)
            Text("Someone else").tag(false)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("name-clips-who")
    }
}
