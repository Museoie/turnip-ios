import SwiftUI

/// "Same Trick As…" (`docs/PROFILE_DESIGN.md` §4.5): marks the trick on screen as one with another
/// the user picks, from their own tricks or the whole vocabulary, and lists the names already
/// grouped under it, each of which can be separated again. The two tricks' clips, reps and levels
/// count together on this iPhone at once; while the user contributes, the pair also goes to the
/// farm as a suggestion for everyone's vocabulary.
struct TrickSynonymSheet: View {
    let trick: Trick
    /// The tricks the user's clips resolve to, the gallery's order.
    let ownTricks: [Trick]
    @ObservedObject var vocabulary: VocabularyStore
    /// Called with the trick the screen shows once two are one.
    let merged: (Trick) -> Void
    var account: FarmAccount = .shared
    var contributes: @MainActor () -> Bool = { TurnipSettingsStore.shared.contributesClips }

    @State private var query = ""
    @State private var picked: Trick?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                grouped
                section("Your Tricks", tricks: matchingOwn, identifier: "trick-synonyms-own")
                section("All Tricks", tricks: matchingVocabulary, identifier: "trick-synonyms-vocabulary")
            }
            .overlay {
                if matchingOwn.isEmpty && matchingVocabulary.isEmpty && groupedSynonyms.isEmpty {
                    Text("No other tricks.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Search tricks")
            .navigationTitle("Same Trick As…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                pickedTitle, isPresented: isPicking, titleVisibility: .visible, presenting: picked
            ) { other in
                Button(String(localized: "Keep “\(other.title)”")) { merge(trick, into: other) }
                Button(String(localized: "Keep “\(trick.title)”")) { merge(other, into: trick) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(pickedMessage)
            }
        }
        .accessibilityIdentifier("trick-synonyms")
    }

    // MARK: - Lists

    /// The names the user grouped under this trick, newest last.
    private var groupedSynonyms: [TrickSynonym] {
        vocabulary.synonyms(groupedUnder: trick)
    }

    @ViewBuilder
    private var grouped: some View {
        if !groupedSynonyms.isEmpty {
            Section {
                ForEach(groupedSynonyms, id: \.self) { synonym in
                    HStack {
                        Text(synonym.name)
                        Spacer()
                        Button("Separate") { vocabulary.removeSynonym(synonym) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "Separate \(synonym.name)"))
                    }
                }
            } header: {
                Text("Grouped Under \(trick.title)")
            } footer: {
                Text("Names you marked as this trick. Separating one counts it as its own trick again.")
            }
            .accessibilityIdentifier("trick-synonyms-grouped")
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, tricks: [Trick], identifier: String) -> some View {
        if !tricks.isEmpty {
            Section(title) {
                ForEach(tricks, id: \.key) { other in
                    Button { picked = other } label: { row(for: other) }
                        .foregroundStyle(.primary)
                }
            }
            .accessibilityIdentifier(identifier)
        }
    }

    /// The trick's name, and under it the other spellings the vocabulary has for it.
    private func row(for other: Trick) -> some View {
        let spellings = otherSpellings(of: other)
        return VStack(alignment: .leading, spacing: 2) {
            Text(other.title)
            if !spellings.isEmpty {
                Text(spellings.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var matchingOwn: [Trick] {
        ownTricks.filter { $0.key != trick.key && matches($0) }
    }

    /// Every canonical name the vocabulary has, the farm's and the user's own, without the user's
    /// tricks listed above.
    private var matchingVocabulary: [Trick] {
        let own = Set(ownTricks.map(\.key))
        return vocabulary.current.entries
            .map { Trick(key: TrickVocabulary.normalized($0.canonical), name: $0.canonical) }
            .filter { $0.key != trick.key && !own.contains($0.key) && matches($0) }
    }

    private func matches(_ other: Trick) -> Bool {
        let key = TrickVocabulary.normalized(query)
        guard !key.isEmpty else { return true }
        return ([other.name] + otherSpellings(of: other)).contains { TrickVocabulary.normalized($0).contains(key) }
    }

    private func otherSpellings(of other: Trick) -> [String] {
        let entries = vocabulary.current.entries
        guard let entry = entries.first(where: { TrickVocabulary.normalized($0.canonical) == other.key }) else {
            return []
        }
        var seen: Set<String> = [other.key]
        return entry.aliases.filter { seen.insert(TrickVocabulary.normalized($0)).inserted }
    }

    // MARK: - Merging

    private var isPicking: Binding<Bool> {
        Binding(get: { picked != nil }, set: { if !$0 { picked = nil } })
    }

    private var pickedTitle: String {
        guard let picked else { return "" }
        return String(localized: "Are “\(trick.title)” and “\(picked.title)” the same trick?")
    }

    private var pickedMessage: String {
        contributes()
            ? String(localized: """
                Their clips, reps and levels count together on this iPhone. The two names also go to \
                the farm as a suggestion for everyone's trick names.
                """)
            : String(localized: "Their clips, reps and levels count together on this iPhone.")
    }

    /// `name`'s trick goes under `kept`'s, which keeps its name, and the screen follows to it.
    private func merge(_ name: Trick, into kept: Trick) {
        let suggests = contributes()
        vocabulary.addSynonym(TrickSynonym(name: name.name, sameAs: kept.name), suggest: suggests)
        let canonical = vocabulary.current.canonicalName(for: kept.name) ?? kept.name
        merged(Trick(key: TrickVocabulary.normalized(canonical), name: canonical))
        if suggests {
            let vocabulary = self.vocabulary, account = self.account
            Task { await vocabulary.sendSynonyms(account: account, contributes: true) }
        }
        dismiss()
    }
}
