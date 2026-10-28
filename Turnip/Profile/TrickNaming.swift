import Foundation

/// A trick the Profile counts and groups by: a canonical name from the vocabulary, or the
/// normalized text of a name the vocabulary doesn't map yet, which is still the user's trick.
struct Trick: Hashable, Sendable {
    /// Normalized: what grouping compares.
    let key: String
    /// The vocabulary's spelling, or the normalized name for one it doesn't know.
    let name: String

    /// The name as a title: "Gainer".
    var title: String { name.prefix(1).uppercased() + name.dropFirst() }

    /// A stable identifier fragment: the key with its spaces as dashes.
    var identifier: String { key.replacingOccurrences(of: " ", with: "-") }
}

/// Resolves names to tricks with the pipeline training uses (`docs/PROFILE_DESIGN.md` §4.4,
/// `TRAINING_DESIGN.md` §2.2): normalize, strip parentheticals, look the whole label up — as given,
/// then without parentheticals — and only on a miss split it on `-`, `/`, `+` and `,` and look up
/// each part. A part the vocabulary doesn't map keeps its normalized text, so it groups by itself
/// until a vocabulary update maps it.
enum TrickNaming {
    private static let separators: Set<Character> = ["-", "/", "+", ","]

    static func tricks(for label: String, vocabulary: TrickVocabulary) -> [Trick] {
        let normalized = TrickVocabulary.normalized(label)
        guard !normalized.isEmpty else { return [] }
        if let canonical = vocabulary.canonicalName(for: normalized) { return [trick(canonical)] }
        let stripped = TrickVocabulary.normalized(
            normalized.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression))
        if !stripped.isEmpty, let canonical = vocabulary.canonicalName(for: stripped) { return [trick(canonical)] }
        let parts = stripped
            .split(whereSeparator: { separators.contains($0) })
            .map { TrickVocabulary.normalized(String($0)) }
            .filter { !$0.isEmpty }
        return distinct(parts.map { part in
            vocabulary.canonicalName(for: part).map(trick) ?? Trick(key: part, name: part)
        })
    }

    /// Every distinct trick a clip's names resolve to, in the order the names give them: a combo
    /// counts once under each of its tricks.
    static func tricks(in names: [ClipName], vocabulary: TrickVocabulary) -> [Trick] {
        distinct(names.flatMap { tricks(for: $0.name, vocabulary: vocabulary) })
    }

    private static func trick(_ canonical: String) -> Trick {
        Trick(key: TrickVocabulary.normalized(canonical), name: canonical)
    }

    private static func distinct(_ tricks: [Trick]) -> [Trick] {
        var seen = Set<String>()
        return tricks.filter { seen.insert($0.key).inserted }
    }
}

/// The Profile's gallery (`docs/PROFILE_DESIGN.md` §7): saved clips grouped by trick, a combo under
/// each of its tricks.
enum TrickGallery {
    struct Group: Identifiable, Hashable {
        let trick: Trick
        /// Newest first.
        let clips: [LibraryClip]

        var id: String { trick.key }
    }

    /// Which clips the gallery shows: the user's own (the default), or everyone filmed.
    enum Filter: Hashable, CaseIterable {
        case mine
        case everyone
    }

    /// One group per trick with a clip the filter keeps, the trick practiced most recently first.
    static func groups(of clips: [LibraryClip], filter: Filter, vocabulary: TrickVocabulary) -> [Group] {
        var byTrick: [String: (trick: Trick, clips: [LibraryClip])] = [:]
        for clip in clips where filter == .everyone || clip.isMe {
            for trick in TrickNaming.tricks(in: clip.names, vocabulary: vocabulary) {
                byTrick[trick.key, default: (trick, [])].clips.append(clip)
            }
        }
        return byTrick.values
            .map { Group(trick: $0.trick, clips: $0.clips.sorted(by: newestFirst)) }
            .sorted { lhs, rhs in
                let lhsLatest = lhs.clips.first?.recordedAt ?? .distantPast
                let rhsLatest = rhs.clips.first?.recordedAt ?? .distantPast
                return lhsLatest != rhsLatest ? lhsLatest > rhsLatest : lhs.trick.key < rhs.trick.key
            }
    }

    static func newestFirst(_ lhs: LibraryClip, _ rhs: LibraryClip) -> Bool {
        lhs.recordedAt != rhs.recordedAt ? lhs.recordedAt > rhs.recordedAt : lhs.id.uuidString < rhs.id.uuidString
    }
}
