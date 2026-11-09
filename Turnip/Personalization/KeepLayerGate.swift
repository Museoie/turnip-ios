import Foundation

/// One labeled band segment, as the keep layer learns from it (`docs/PERSONALIZATION_DESIGN.md`
/// §4.3): kept when it matches a saved clip, dismissed when it matches a trashed proposal.
struct KeepExample: Sendable {
    let score: Float
    /// Unit length.
    let vector: [Float]
    let isKept: Bool
    /// When it happened: its source's recording date plus its offset into the source, what the
    /// gate's newest-first holdout reads (§5).
    let recordedAt: Date
    /// The pose it was found on and where, so examples recorded at the same moment keep one order.
    let poseID: String
    let startFrame: Int

    /// Every labeled band segment of the library's stored poses. A segment matching a saved clip is
    /// kept even where it matches a trashed proposal too: a "+" clip over a trashed tile says a
    /// trick is there. One matching neither has no label and is left out. A pose no clip names
    /// isn't stored, and contributes nothing.
    static func examples(
        bandSegments: [String: [BandSegment]], clips: [LibraryClip], dismissed: [DismissedWindow]
    ) -> [KeepExample] {
        var clipsByPose: [String: [LibraryClip]] = [:]
        for clip in clips {
            if let poseID = clip.poseID { clipsByPose[poseID, default: []].append(clip) }
        }
        let dismissedByPose = Dictionary(grouping: dismissed, by: \.poseID)
        var examples: [KeepExample] = []
        for (poseID, segments) in bandSegments {
            guard let poseClips = clipsByPose[poseID],
                  let sourceStart = poseClips.map({ $0.recordedAt.addingTimeInterval(-$0.startTime) }).min()
            else { continue }
            let saved = poseClips.map { clip -> (start: Int, end: Int) in
                ContributionPose.canonicalFrames(
                    of: TrickWindow(startTime: clip.startTime, endTime: clip.endTime), frameCount: Int.max)
            }
            let trashed = (dismissedByPose[poseID] ?? []).map { (start: $0.startFrame, end: $0.endFrame) }
            for segment in segments {
                let frames = (start: segment.startFrame, end: segment.endFrame)
                let isKept: Bool
                if saved.contains(where: { matches($0, frames) }) {
                    isKept = true
                } else if trashed.contains(where: { matches($0, frames) }) {
                    isKept = false
                } else {
                    continue
                }
                examples.append(KeepExample(
                    score: segment.score, vector: segment.vector, isKept: isKept,
                    recordedAt: sourceStart.addingTimeInterval(
                        Double(segment.startFrame) / Double(ContributionPose.canonicalRate)),
                    poseID: poseID, startFrame: segment.startFrame))
            }
        }
        return examples
    }

    /// Whether two frame ranges are the same trick: their overlap covers at least half of the
    /// shorter of the two. *(Judgment call, §4.3.)*
    static func matches(_ lhs: (start: Int, end: Int), _ rhs: (start: Int, end: Int)) -> Bool {
        let shorter = min(lhs.end - lhs.start, rhs.end - rhs.start)
        let overlap = min(lhs.end, rhs.end) - max(lhs.start, rhs.start)
        return shorter > 0 && 2 * overlap >= shorter
    }
}

/// Whether the keep layer beats the central model on the user's own newest band segments
/// (`docs/PERSONALIZATION_DESIGN.md` §5): it is fit without the newest fifth of them, and passes
/// when its log loss on those is lower than the central model's, `p = s`.
enum KeepLayerGate {
    /// Too few labeled band segments, or too few of either label, to say anything (§4.3).
    static let minimumExamples = 20
    static let minimumPerLabel = 5
    /// The newest share held out, and the fewest.
    static let heldOutShare = 0.2
    static let minimumHeldOut = 5

    struct Outcome: Equatable, Sendable {
        let examples: Int
        let heldOut: Int
        let personalLoss: Double
        let centralLoss: Double

        /// A tie leaves the layer off: it would only add a refit.
        var passes: Bool { personalLoss < centralLoss }
    }

    /// `nil` with too few examples to measure.
    static func outcome(
        of examples: [KeepExample], width: Int, penalty: Double = PersonalKeepLayer.penalty
    ) -> Outcome? {
        let kept = examples.filter(\.isKept).count
        guard examples.count >= minimumExamples, kept >= minimumPerLabel,
              examples.count - kept >= minimumPerLabel
        else { return nil }
        let newestFirst = examples.sorted { lhs, rhs in
            if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
            if lhs.poseID != rhs.poseID { return lhs.poseID < rhs.poseID }
            return lhs.startFrame > rhs.startFrame
        }
        let heldOutCount = max(minimumHeldOut, Int((Double(examples.count) * heldOutShare).rounded(.up)))
        let heldOut = Array(newestFirst.prefix(heldOutCount))
        let fitted = KeepLayerFit.fit(Array(newestFirst.dropFirst(heldOutCount)), width: width, penalty: penalty)
        return Outcome(
            examples: examples.count, heldOut: heldOut.count,
            personalLoss: KeepLayerFit.logLoss(of: fitted, over: heldOut),
            centralLoss: KeepLayerFit.logLoss(of: .prior(width: width), over: heldOut))
    }
}
