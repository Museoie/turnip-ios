import Foundation

/// Labels come only from the vocabulary (`BACKEND_DESIGN.md` §1.2.25): a name the vocabulary lacks
/// is whatever the user typed, so it goes to the farm on its own, as a suggestion for the
/// vocabulary, and never with a clip's pose (`docs/CONTRIBUTION_DESIGN.md` §4).
extension SourceContribution {
    /// The contribution with only the names `vocabulary` knows, and the names it doesn't, each
    /// once in the order first met. A clip left with no known name isn't contributed; `known` is
    /// `nil` when no clip is left.
    func splitByVocabulary(_ vocabulary: TrickVocabulary) -> (known: SourceContribution?, unknown: [String]) {
        var seen = Set<String>()
        let unknown = clips.flatMap(\.names).map(\.name).filter { name in
            !vocabulary.knows(name) && seen.insert(TrickVocabulary.farmNormalized(name)).inserted
        }
        return (droppingNames(unknown), unknown)
    }

    /// The contribution without `names`, compared as the farm compares them (`farmNormalized`). A
    /// clip left with no name isn't contributed; `nil` when no clip is left.
    func droppingNames(_ names: [String]) -> SourceContribution? {
        let dropped = Set(names.map(TrickVocabulary.farmNormalized))
        let kept = clips.compactMap { clip -> ClipContribution? in
            var clip = clip
            clip.names.removeAll { dropped.contains(TrickVocabulary.farmNormalized($0.name)) }
            return clip.names.isEmpty ? nil : clip
        }
        guard !kept.isEmpty else { return nil }
        return SourceContribution(videoID: videoID, pose: pose, clips: kept)
    }

    /// Every name on every clip, counted once per clip it is on.
    var nameCount: Int { clips.reduce(0) { $0 + $1.names.count } }
}

/// What `POST /api/labels/candidates` accepts (`BACKEND_DESIGN.md` §7.3): 1 to 20 names, each 1 to
/// 64 characters after trimming, counted as the farm counts them, in UTF-16 code units.
enum LabelCandidates {
    static let maximumCount = 20
    static let maximumLength = 64

    /// `names` trimmed, without blanks, overlong ones or repeats (ignoring case and spacing), and
    /// at most `maximumCount` of them.
    static func batch(_ names: [String]) -> [String] {
        var seen = Set<String>()
        let usable = names
            .map(TrickVocabulary.farmTrimmed)
            .filter { name in
                !name.isEmpty && name.utf16.count <= maximumLength
                    && seen.insert(TrickVocabulary.farmNormalized(name)).inserted
            }
        return Array(usable.prefix(maximumCount))
    }
}
