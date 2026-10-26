import Foundation

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
    /// is near none.
    func suggestedCorrection(for typed: String) -> String? {
        let key = Self.normalized(typed)
        guard !key.isEmpty, !entries.contains(where: { Self.normalized($0.canonical) == key }) else { return nil }
        if let canonical = canonicalName(for: key) { return canonical }
        let allowed = key.count > 7 ? 2 : 1
        var best: (canonical: String, distance: Int)?
        for entry in entries {
            for spelling in [entry.canonical] + entry.aliases {
                let distance = Self.editDistance(key, Self.normalized(spelling))
                if distance <= allowed, distance < (best?.distance ?? .max) {
                    best = (entry.canonical, distance)
                }
            }
        }
        return best?.canonical
    }

    /// Lowercased, trimmed, with runs of whitespace collapsed to one space.
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
@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore(
        client: FarmConfiguration.endpoint.map(FarmClient.live), cacheURL: VocabularyStore.defaultCacheURL)

    @Published private(set) var current: TrickVocabulary

    private let client: FarmClient?
    private let cacheURL: URL?
    private var lastRefresh: Date?
    /// The farm's vocabulary changes when its curators remap names, not by the minute.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    init(client: FarmClient?, cacheURL: URL?) {
        self.client = client
        self.cacheURL = cacheURL
        let cached = cacheURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(TrickVocabulary.self, from: $0) }
        current = [TrickVocabulary.seed, cached].compactMap { $0 }.max { $0.taxonomyVersion < $1.taxonomyVersion }
            ?? .seed
    }

    /// Fetches the farm's vocabulary when the last fetch is more than `refreshInterval` old, and
    /// adopts it only when it is newer. A failed fetch keeps what is held; naming never waits on it.
    func refreshIfStale(now: Date = Date()) async {
        guard let client else { return }
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        lastRefresh = now
        guard let fetched = try? await client.currentTaxonomy(),
              fetched.taxonomyVersion > current.taxonomyVersion
        else { return }
        current = fetched
        if let cacheURL, let data = try? JSONEncoder().encode(fetched) {
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    nonisolated static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("turnip-vocabulary.json")
    }
}
