import Foundation

/// Two names the user marked as one trick (`docs/PROFILE_DESIGN.md` §4.5): `name`'s trick goes under
/// `sameAs`'s, whose name it keeps. The same shape as a pair in the farm's
/// `POST /api/labels/synonyms`.
struct TrickSynonym: Codable, Hashable, Sendable {
    let name: String
    let sameAs: String

    enum CodingKeys: String, CodingKey {
        case name
        case sameAs = "same_as"
    }
}

/// The trick names the naming step suggests (`docs/PROFILE_DESIGN.md` §4.2): one entry per
/// canonical name with every raw spelling the farm maps to it, at a `taxonomyVersion`. The same
/// shape as the farm's `GET /api/taxonomy/current` and the model manifest's `vocabulary`, so
/// either decodes straight into it. Suggestions only: a typed name outside it is as valid as any.
struct TrickVocabulary: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let canonical: String
        let aliases: [String]
    }

    let taxonomyVersion: Int
    let entries: [Entry]
    /// Spellings, `normalized`, that only the user's own synonyms put here (`merging`): they group
    /// on this device, but the farm doesn't know them, so `knows` and a pick's origin leave them
    /// out. Never encoded: a fetched vocabulary is the farm's alone.
    var personalSpellings: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case taxonomyVersion = "taxonomy_version"
        case entries = "vocabulary"
    }

    /// Bundled with the app, so naming has suggestions before the first fetch and offline: the
    /// farm's version-1 seed.
    static let seed = TrickVocabulary(taxonomyVersion: 1, entries: [
        Entry(canonical: "cartfull", aliases: ["cartfull"]),
        Entry(canonical: "cork", aliases: ["cork", "corkscrew"]),
        Entry(canonical: "gainer", aliases: ["gainer"]),
        Entry(canonical: "hook", aliases: ["hook"]),
        Entry(canonical: "scoot", aliases: ["scoot"])
    ])

    /// Whether `name` may go to the farm as a label (`BACKEND_DESIGN.md` §1.2.25): its
    /// `farmNormalized` form equals that of a canonical name or of any spelling of one. The farm
    /// applies the same rule across every taxonomy version, so this is the one place the app
    /// decides it.
    func knows(_ name: String) -> Bool {
        let key = Self.farmNormalized(name)
        guard !key.isEmpty else { return false }
        return entries.contains { entry in
            ([entry.canonical] + entry.aliases).contains { spelling in
                Self.farmNormalized(spelling) == key && !isPersonal(spelling)
            }
        }
    }

    /// Whether `name` is here only because of the user's own synonyms.
    func isPersonal(_ name: String) -> Bool {
        personalSpellings.contains(Self.normalized(name))
    }

    /// This vocabulary with the user's synonyms applied in order (`docs/PROFILE_DESIGN.md` §4.5): each
    /// moves every spelling of `name`'s trick into `sameAs`'s, the way the farm's merge does, so
    /// grouping, counts and suggestions treat them as one trick. A name the vocabulary lacks joins as
    /// a spelling of its own, and a `sameAs` it lacks becomes a canonical name; both are
    /// `personalSpellings`. A synonym whose names are already one trick, such as one the farm has
    /// since merged too, changes nothing.
    func merging(_ synonyms: [TrickSynonym]) -> TrickVocabulary {
        guard !synonyms.isEmpty else { return self }
        var entries = entries
        var personal = personalSpellings
        func index(of name: String) -> Int? {
            let key = Self.normalized(name)
            return entries.firstIndex { entry in
                ([entry.canonical] + entry.aliases).contains { Self.normalized($0) == key }
            }
        }
        for synonym in synonyms {
            let nameKey = Self.normalized(synonym.name), sameAsKey = Self.normalized(synonym.sameAs)
            guard !nameKey.isEmpty, !sameAsKey.isEmpty, nameKey != sameAsKey else { continue }
            let kept: Int
            if let found = index(of: synonym.sameAs) {
                kept = found
            } else {
                entries.append(Entry(canonical: synonym.sameAs, aliases: [synonym.sameAs]))
                personal.insert(Self.normalized(synonym.sameAs))
                kept = entries.count - 1
            }
            let joining: [String]
            if let moved = index(of: synonym.name) {
                guard moved != kept else { continue }
                joining = [entries[moved].canonical] + entries[moved].aliases
                entries[kept] = Entry(canonical: entries[kept].canonical, aliases: entries[kept].aliases + joining)
                entries.remove(at: moved)
            } else {
                joining = [synonym.name]
                entries[kept] = Entry(canonical: entries[kept].canonical, aliases: entries[kept].aliases + joining)
                personal.insert(Self.normalized(synonym.name))
            }
        }
        var merged = TrickVocabulary(taxonomyVersion: taxonomyVersion, entries: entries)
        merged.personalSpellings = personal
        return merged
    }

    /// The canonical name `name` is spelled as, ignoring case and spacing; `nil` outside the
    /// vocabulary.
    func canonicalName(for name: String) -> String? {
        let key = Self.normalized(name)
        return entries.first { entry in
            Self.normalized(entry.canonical) == key || entry.aliases.contains { Self.normalized($0) == key }
        }?.canonical
    }

    /// Canonical names whose name or a spelling of it contains `query`, the ones that start with
    /// it first. Every canonical name, in vocabulary order, for an empty query.
    func names(matching query: String) -> [String] {
        let key = Self.normalized(query)
        guard !key.isEmpty else { return entries.map(\.canonical) }
        func spellings(_ entry: Entry) -> [String] { ([entry.canonical] + entry.aliases).map(Self.normalized) }
        let prefixed = entries.filter { spellings($0).contains { $0.hasPrefix(key) } }
        let containing = entries.filter { entry in
            !prefixed.contains(entry) && spellings(entry).contains { $0.contains(key) }
        }
        return (prefixed + containing).map(\.canonical)
    }

    /// The canonical name to offer in place of `typed` (`docs/PROFILE_DESIGN.md` §4.2 "Did you
    /// mean"): a known spelling of it, or within a small edit distance of one — one edit for
    /// names up to seven letters, two above. `nil` when `typed` already is a canonical name or
    /// is near none. Only a canonical name the farm knows is offered: the replacement is a pick
    /// from the vocabulary, and one of the user's own synonyms isn't in the farm's.
    func suggestedCorrection(for typed: String) -> String? {
        let key = Self.normalized(typed)
        guard !key.isEmpty, !entries.contains(where: { Self.normalized($0.canonical) == key }) else { return nil }
        let offered = entries.filter { !isPersonal($0.canonical) }
        if let entry = offered.first(where: { $0.aliases.contains { Self.normalized($0) == key } }) {
            return entry.canonical
        }
        let allowed = key.count > 7 ? 2 : 1
        var best: (canonical: String, distance: Int)?
        for entry in offered {
            for spelling in [entry.canonical] + entry.aliases {
                let distance = Self.editDistance(key, Self.normalized(spelling))
                if distance <= allowed, distance < (best?.distance ?? .max) {
                    best = (entry.canonical, distance)
                }
            }
        }
        return best?.canonical
    }

    /// What the farm counts as whitespace in a name (`BACKEND_DESIGN.md` §1.2.25, `normalizeName`):
    /// ASCII space, tab, line feed, vertical tab, form feed and carriage return, and nothing else.
    /// A no-break space or any other Unicode space is an ordinary character to it.
    static let farmWhitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r"]

    /// A name as the farm compares it: trimmed of `farmWhitespace`, runs of it collapsed to one
    /// space, lowercased. Split by Unicode scalar, so a CR LF pair, one `Character`, counts too.
    static func farmNormalized(_ name: String) -> String {
        name.unicodeScalars
            .split(whereSeparator: { farmWhitespace.contains($0) })
            .map { String(Substring($0)) }
            .joined(separator: " ")
            .lowercased()
    }

    /// `farmNormalized`'s trimming alone: what the farm measures a candidate name by.
    static func farmTrimmed(_ name: String) -> String {
        let scalars = name.unicodeScalars
        guard let first = scalars.firstIndex(where: { !farmWhitespace.contains($0) }),
              let last = scalars.lastIndex(where: { !farmWhitespace.contains($0) })
        else { return "" }
        return String(Substring(scalars[first...last]))
    }

    /// Lowercased, trimmed, with runs of whitespace collapsed to one space: how names group on
    /// this device, the same as turnip-ml's canonicalization, which splits on any Unicode
    /// whitespace. What the farm accepts is `farmNormalized`.
    static func normalized(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Levenshtein distance over characters.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs), rhs = Array(rhs)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: rhs.count)
            for (column, right) in rhs.enumerated() {
                let substitution = previous[column] + (left == right ? 0 : 1)
                current[column + 1] = min(substitution, previous[column + 1] + 1, current[column] + 1)
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

/// The newest vocabulary the app holds (`docs/PROFILE_DESIGN.md` §4.2): the bundled seed, or the
/// farm's current one once fetched, whichever has the greater `taxonomyVersion`. The fetched one
/// is kept in Application Support so it survives a relaunch offline.
///
/// Over it, the user's own synonyms (§4.5): two tricks marked as one group as one on this device at
/// once, and are sent to the farm as a suggestion while the user contributes. The farm applies a
/// suggestion only when its maintainer merges the two, and then every app gets it with the
/// vocabulary.
@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore(
        client: FarmConfiguration.endpoint.map(FarmClient.live), cacheURL: VocabularyStore.defaultCacheURL,
        synonymsURL: VocabularyStore.defaultSynonymsURL)

    /// The farm's vocabulary with the user's synonyms applied: what naming, grouping and the Profile
    /// read.
    @Published private(set) var current: TrickVocabulary
    /// The user's synonyms, oldest first.
    @Published private(set) var synonyms: [TrickSynonym]
    /// The farm's vocabulary alone: what a contribution's names are checked against, and what a
    /// fetch is compared with.
    private(set) var farm: TrickVocabulary {
        didSet { current = farm.merging(synonyms) }
    }

    private let client: FarmClient?
    private let cacheURL: URL?
    private let synonymsURL: URL?
    /// Synonyms made while contributing that the farm hasn't been sent yet.
    private var unsent: [TrickSynonym]
    private var lastRefresh: Date?
    private var isSending = false
    /// The farm's vocabulary changes when its curators remap names, not by the minute.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    /// What the synonyms file holds.
    private struct SynonymsFile: Codable {
        var synonyms: [TrickSynonym]
        var unsent: [TrickSynonym]
    }

    init(client: FarmClient?, cacheURL: URL?, synonymsURL: URL? = nil) {
        self.client = client
        self.cacheURL = cacheURL
        self.synonymsURL = synonymsURL
        let cached = cacheURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(TrickVocabulary.self, from: $0) }
        let farm = [TrickVocabulary.seed, cached].compactMap { $0 }.max { $0.taxonomyVersion < $1.taxonomyVersion }
            ?? .seed
        let file = synonymsURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(SynonymsFile.self, from: $0) }
        self.farm = farm
        synonyms = file?.synonyms ?? []
        unsent = file?.unsent ?? []
        current = farm.merging(file?.synonyms ?? [])
    }

    /// Fetches the farm's vocabulary when the last fetch is more than `refreshInterval` old, and
    /// adopts it only when it is newer. A failed fetch keeps what is held; naming never waits on it.
    func refreshIfStale(now: Date = Date()) async {
        guard let client else { return }
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        lastRefresh = now
        guard let fetched = try? await client.currentTaxonomy(),
              fetched.taxonomyVersion > farm.taxonomyVersion
        else { return }
        farm = fetched
        if let cacheURL, let data = try? JSONEncoder().encode(fetched) {
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - The user's synonyms

    /// Marks `name`'s trick as `sameAs`'s, keeping `sameAs`'s name. `suggest` queues the pair for
    /// the farm: true while the user contributes. Two names already one trick change nothing.
    func addSynonym(_ synonym: TrickSynonym, suggest: Bool) {
        guard current.merging([synonym]) != current else { return }
        synonyms.append(synonym)
        if suggest { unsent.append(synonym) }
        current = farm.merging(synonyms)
        persistSynonyms()
    }

    /// Undoes one of the user's synonyms: its names group as the farm's vocabulary and the user's
    /// other synonyms have them. A suggestion already sent stays with the farm, where it expires.
    func removeSynonym(_ synonym: TrickSynonym) {
        synonyms.removeAll { $0 == synonym }
        unsent.removeAll { $0 == synonym }
        current = farm.merging(synonyms)
        persistSynonyms()
    }

    /// The user's synonyms that put a name in `trick`'s group, each one's `name` being a name it
    /// merged in.
    func synonyms(groupedUnder trick: Trick) -> [TrickSynonym] {
        synonyms.filter { synonym in
            current.canonicalName(for: synonym.sameAs).map(TrickVocabulary.normalized) == trick.key
        }
    }

    /// Sends the queued synonyms to the farm while `contributes`, with the account's session
    /// (`POST /api/labels/synonyms`). With contributing off, the queue is dropped, as the outbox's
    /// is. A failure keeps the queue for the next launch or foreground; a dead session signs out.
    func sendSynonyms(account: FarmAccount, contributes: Bool) async {
        guard !isSending, !unsent.isEmpty else { return }
        guard contributes else {
            unsent = []
            persistSynonyms()
            return
        }
        guard let client, account.isSignedIn, account.credentials.hasConsented,
              let session = account.credentials.sessionToken
        else { return }
        let batch = Array(unsent.prefix(SynonymCandidates.maximumCount))
        let pairs = SynonymCandidates.batch(batch)
        isSending = true
        defer { isSending = false }
        do {
            if !pairs.isEmpty { try await client.suggestSynonyms(pairs, session: session) }
        } catch FarmError.unauthenticated {
            account.sessionEnded()
            return
        } catch {
            // Kept for the next try unless the farm refused them for good; a suggestion is never
            // worth holding anything up.
            guard Self.refusesForGood(error) else { return }
        }
        unsent.removeAll { batch.contains($0) }
        persistSynonyms()
    }

    /// A refusal another try would get again: the farm answered, and not with a rate limit or a
    /// failure of its own. A `404` is a farm without `POST /api/labels/synonyms` yet, one deployed
    /// before it, so the pair waits for the farm that has it; `408` and `429` pass with time.
    nonisolated static func refusesForGood(_ error: Error) -> Bool {
        switch error as? FarmError {
        case .rejected(let code, _)?: return code != "NOT_FOUND"
        case .accountBlocked?: return true
        case .http(let status)?: return (400..<500).contains(status) && ![404, 408, 429].contains(status)
        default: return false
        }
    }

    private func persistSynonyms() {
        guard let synonymsURL,
              let data = try? JSONEncoder().encode(SynonymsFile(synonyms: synonyms, unsent: unsent))
        else { return }
        try? FileManager.default.createDirectory(
            at: synonymsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: synonymsURL, options: .atomic)
    }

    nonisolated static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("turnip-vocabulary.json")
    }

    nonisolated static var defaultSynonymsURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("turnip-synonyms.json")
    }
}
