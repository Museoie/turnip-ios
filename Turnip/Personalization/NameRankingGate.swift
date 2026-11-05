import Foundation

/// Whether name ranking beats the central model on the user's own newest clips
/// (`docs/PERSONALIZATION_DESIGN.md` §5). Each clip is held out in turn and scored against the
/// prototypes built without it.
///
/// Both sides are what the naming screen would add beyond tier 1, which is the same with or without
/// the layer. So a held-out clip's listed keys, the ones named on its video's other clips, come out
/// of both before each is cut at three, and a repeat within a session scores for neither side.
enum NameRankingGate {
    /// How many of the newest clips are held out, and how few are too few to say anything.
    static let heldOutClips = 50
    static let minimumClips = 10

    struct Outcome: Equatable, Sendable {
        let clips: Int
        let personalHits: Int
        let centralHits: Int

        /// A tie would add nothing, so it leaves ranking off.
        var passes: Bool { personalHits > centralHits }
    }

    /// `nil` with too few clips to measure.
    static func outcome(of examples: [PersonalExample]) -> Outcome? {
        let newest = examples
            .sorted { lhs, rhs in
                guard lhs.recordedAt == rhs.recordedAt else { return lhs.recordedAt > rhs.recordedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(heldOutClips)
        guard newest.count >= minimumClips else { return nil }
        let prototypes = NamePrototypes(examples)
        let count = PersonalNameRanking.suggestionCount
        var personalHits = 0, centralHits = 0
        for clip in newest {
            let names = Set(clip.weights.keys)
            let personal = prototypes.all(leavingOut: clip)
                .nearest(to: clip.vector, count: count, excluding: clip.listedKeys)
                .map(\.key)
            let central = clip.centralKeys.filter { !clip.listedKeys.contains($0) }.prefix(count)
            if !names.isDisjoint(with: personal) { personalHits += 1 }
            if !names.isDisjoint(with: central) { centralHits += 1 }
        }
        return Outcome(clips: newest.count, personalHits: personalHits, centralHits: centralHits)
    }
}
