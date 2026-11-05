import Foundation

/// One named clip with an embedding, as the personal layer learns from it
/// (`docs/PERSONALIZATION_DESIGN.md` §3, §4.2).
struct PersonalExample: Sendable {
    let id: UUID
    let vector: [Float]
    /// The keys its names resolve to, each with its name's weight: a combo counts toward each of
    /// its names, and a key two names share takes the greater weight, so a clip counts once.
    let weights: [String: Float]
    /// How the clip spells each key, for showing a name the vocabulary doesn't map.
    let spellings: [String: String]
    /// The central model's names for the clip as keys, surest first.
    let centralKeys: [String]
    /// The keys named on the video's other clips: what tier 1 already lists when this one is named.
    let listedKeys: Set<String>
    let recordedAt: Date

    /// A kept pre-fill is the weakest evidence there is, since keeping one costs nothing
    /// (`TRAINING_DESIGN.md` §6.4).
    static func weight(of origin: LabelOrigin) -> Float {
        origin == .model ? 0.5 : 1
    }

    /// The clips the layer can learn from: named, and embedded under the active model.
    static func examples(
        from clips: [LibraryClip], embeddings: [String: ClipEmbedding], vocabulary: TrickVocabulary
    ) -> [PersonalExample] {
        let keysByClip = clips.reduce(into: [UUID: Set<String>]()) { keys, clip in
            keys[clip.id] = Set(TrickNaming.tricks(in: clip.names, vocabulary: vocabulary).map(\.key))
        }
        let clipsBySource = Dictionary(grouping: clips, by: \.sourceAssetID)
        return clips.compactMap { clip in
            guard let embedding = embeddings[clip.id.uuidString], !clip.names.isEmpty else { return nil }
            let others = (clipsBySource[clip.sourceAssetID] ?? []).filter { $0.id != clip.id }
            var seen = Set<String>()
            return PersonalExample(
                id: clip.id, vector: embedding.vector,
                weights: weights(of: clip.names, vocabulary: vocabulary),
                spellings: spellings(of: clip.names, vocabulary: vocabulary),
                centralKeys: embedding.centralNames
                    .flatMap { TrickNaming.tricks(for: $0, vocabulary: vocabulary).map(\.key) }
                    .filter { seen.insert($0).inserted },
                listedKeys: others.reduce(into: Set<String>()) { $0.formUnion(keysByClip[$1.id] ?? []) },
                recordedAt: clip.recordedAt)
        }
    }

    private static func weights(of names: [ClipName], vocabulary: TrickVocabulary) -> [String: Float] {
        var weights: [String: Float] = [:]
        for name in names {
            for trick in TrickNaming.tricks(for: name.name, vocabulary: vocabulary) {
                weights[trick.key] = Swift.max(weights[trick.key] ?? 0, weight(of: name.origin))
            }
        }
        return weights
    }

    /// The vocabulary's spelling of a name it maps. The user's own for one it doesn't, unless the
    /// name was a combo written out, whose parts only exist as their normalized text.
    private static func spellings(of names: [ClipName], vocabulary: TrickVocabulary) -> [String: String] {
        var spellings: [String: String] = [:]
        for name in names {
            let tricks = TrickNaming.tricks(for: name.name, vocabulary: vocabulary)
            for trick in tricks {
                let isMapped = vocabulary.canonicalName(for: trick.key) != nil
                spellings[trick.key] = isMapped || tricks.count > 1 ? trick.name : name.name
            }
        }
        return spellings
    }
}

/// A name's place among the user's clips: the origin-weighted mean of their embeddings
/// (`docs/PERSONALIZATION_DESIGN.md` §4.2).
struct NamePrototype: Equatable, Sendable {
    let key: String
    /// The canonical name, or the user's most recent spelling of one that maps to none.
    let name: String
    /// Unit length.
    let vector: [Float]
}

/// Every key's running sums. Sums rather than means, so leaving a clip out is a subtraction
/// (`docs/PERSONALIZATION_DESIGN.md` §5).
struct NamePrototypes: Sendable {
    /// Fewer clips than this say too little about a name for it to have a prototype.
    static let minimumClips = 3

    private struct Sum: Sendable {
        var vector: [Float]
        var clips: Int
        var name: String
        var namedAt: Date
    }

    private var sums: [String: Sum] = [:]

    init(_ examples: [PersonalExample]) {
        for example in examples {
            for (key, weight) in example.weights {
                var sum = sums[key] ?? Sum(
                    vector: [Float](repeating: 0, count: example.vector.count), clips: 0, name: key,
                    namedAt: .distantPast)
                for (column, value) in example.vector.enumerated() {
                    sum.vector[column] += weight * value
                }
                sum.clips += 1
                if example.recordedAt >= sum.namedAt {
                    sum.namedAt = example.recordedAt
                    sum.name = example.spellings[key] ?? key
                }
                sums[key] = sum
            }
        }
    }

    /// The prototypes, as they would be had `example` never been named: a key it brings under
    /// `minimumClips` has none.
    func all(leavingOut example: PersonalExample? = nil) -> [NamePrototype] {
        sums.compactMap { key, sum in
            var vector = sum.vector
            var clips = sum.clips
            if let example, let weight = example.weights[key] {
                for (column, value) in example.vector.enumerated() {
                    vector[column] -= weight * value
                }
                clips -= 1
            }
            guard clips >= Self.minimumClips, let unit = vector.unitLength else { return nil }
            return NamePrototype(key: key, name: sum.name, vector: unit)
        }
    }
}

extension Array where Element == NamePrototype {
    /// The `count` prototypes closest to `vector`, closest first, leaving out `keys`.
    func nearest(to vector: [Float], count: Int, excluding keys: Set<String>) -> [NamePrototype] {
        let candidates = filter { !keys.contains($0.key) }.map { (prototype: $0, similarity: $0.vector.dot(vector)) }
        let ranked = candidates.sorted { lhs, rhs in
            lhs.similarity != rhs.similarity ? lhs.similarity > rhs.similarity : lhs.prototype.key < rhs.prototype.key
        }
        return ranked.prefix(count).map(\.prototype)
    }
}

/// What the personal layer adds to a clip's suggestions: the names used on its video, in the order
/// they should show, and the names to show after them
/// (`docs/PERSONALIZATION_DESIGN.md` §4.2's tiers 1 and 2).
struct PersonalSuggestions: Equatable, Sendable {
    var used: [String]
    var nearest: [String] = []
}

/// Name ranking as it stands: the user's prototypes under one model, built only once the gate has
/// passed (§5).
struct PersonalNameRanking: Sendable {
    /// How many names tier 2 shows, and so what the gate measures it at.
    static let suggestionCount = 3

    let modelVersion: String
    let prototypes: [NamePrototype]
    let vocabulary: TrickVocabulary

    /// `used` ordered by how close each name's prototype is to `vector`, those without one after
    /// them as they came, and the nearest prototypes not already listed or given.
    func suggestions(for vector: [Float], used: [String], given: [ClipName]) -> PersonalSuggestions {
        let similarity = Dictionary(uniqueKeysWithValues: prototypes.map { ($0.key, $0.vector.dot(vector)) })
        func closeness(_ name: String) -> Float? {
            keys(of: name).compactMap { similarity[$0] }.max()
        }
        let ordered = used.enumerated()
            .sorted { lhs, rhs in
                switch (closeness(lhs.element), closeness(rhs.element)) {
                case let (lhsCloseness?, rhsCloseness?) where lhsCloseness != rhsCloseness:
                    return lhsCloseness > rhsCloseness
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
        let listed = Set((used + given.map(\.name)).flatMap(keys(of:)))
        let nearest = prototypes.nearest(to: vector, count: Self.suggestionCount, excluding: listed)
        return PersonalSuggestions(used: ordered, nearest: nearest.map(\.name))
    }

    private func keys(of name: String) -> [String] {
        TrickNaming.tricks(for: name, vocabulary: vocabulary).map(\.key)
    }
}
