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
    let names: [ClipName]
    let isMe: Bool
    /// What the suggestions lead with: the names already given on this clip's video, the user's
    /// own names closest to it, and the model's below-bar names for it.
    let suggested: PersonalSuggestions
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
            suggestionChips
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
                // Return adds the name and keeps the keyboard up for the next one in a combo; on
                // an empty field it puts the keyboard away.
                let addsName = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                commitDraft()
                if isEnabled, addsName { isFieldFocused.wrappedValue = true }
            }
            .accessibilityIdentifier("name-clips-field")
    }

    private var suggestionChips: some View {
        ChipFlow {
            ForEach(suggestions, id: \.self) { name in
                Button(name) {
                    actions.add(name, NamingSuggestions.origin(of: name, vocabulary: vocabulary))
                    draft = ""
                }
                .buttonStyle(ChipButtonStyle(isProminent: false))
            }
        }
        .accessibilityIdentifier("name-clips-suggestions")
    }

    private var suggestions: [String] {
        NamingSuggestions.ordered(draft: draft, given: names, suggested: suggested, vocabulary: vocabulary)
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

/// The naming step's suggestions (`docs/PERSONALIZATION_DESIGN.md` §4.2), the same on every screen
/// that names a clip.
enum NamingSuggestions {
    private static let limit = 8

    /// Names used on this video first, then the user's own names closest to the clip, then the
    /// model's below-bar names, then the vocabulary's matches for what is typed, led by a
    /// near-miss correction; none the clip already has.
    static func ordered(
        draft: String, given: [ClipName], suggested: PersonalSuggestions, vocabulary: TrickVocabulary
    ) -> [String] {
        let query = TrickVocabulary.normalized(draft)
        let personal = (suggested.used + suggested.nearest + suggested.belowBar).filter {
            query.isEmpty || TrickVocabulary.normalized($0).contains(query)
        }
        let corrected = vocabulary.suggestedCorrection(for: draft).map { [$0] } ?? []
        var seen = Set(given.map { TrickVocabulary.normalized($0.name) })
        return (personal + corrected + vocabulary.names(matching: query))
            .filter { seen.insert(TrickVocabulary.normalized($0)).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// A pick from the vocabulary is `vocabulary`. A name the vocabulary doesn't know was typed
    /// once, on this video or an earlier one, so it stays `typed`.
    static func origin(of name: String, vocabulary: TrickVocabulary) -> LabelOrigin {
        vocabulary.canonicalName(for: name) == nil ? .typed : .vocabulary
    }
}
