import Foundation

/// How the trick model proposed a clip (`MODEL_CONTRACT.md` §3.3 steps 5–6): the model, the names
/// it pre-filled, or on a blind clip would have, and whether the clip is in the blind sample. The
/// clip keeps it whatever the user does with the names or the window, and sends it with the clip
/// if it is contributed, so training can tell which names were kept from the model.
struct ModelProposal: Codable, Hashable, Sendable {
    let modelVersion: String
    let suggestedNames: [String]
    let suggestionsWithheld: Bool

    /// The names a clip starts with on Name Clips, as chips the user can keep or remove: none on
    /// a blind clip.
    var prefilledNames: [ClipName] {
        suggestionsWithheld ? [] : suggestedNames.map { ClipName(name: $0, origin: .model) }
    }
}

/// The trick model's per-window embeddings over one person's pose (`MODEL_CONTRACT.md` §3.2.2),
/// kept in memory with the analysis for on-device personalization
/// (`docs/PERSONALIZATION_DESIGN.md` §4.1), which reads them at save. Comparable only with
/// embeddings of the same `modelVersion`.
struct WindowEmbeddings: Hashable, Sendable {
    /// Whose pose they were computed over: a `PoseTrack.id` when the run followed everyone, `nil`
    /// when it followed one person.
    let personID: Int?
    let modelVersion: String
    let windowFrames: Int
    let windowStride: Int
    /// Row `i` covers canonical frames `[i × windowStride, i × windowStride + windowFrames)`.
    let rows: [[Float]]
}

/// The client's postprocessing of the model's segments (`MODEL_CONTRACT.md` §3.3, normative).
struct TrickProposalRules: Sendable {
    /// Step 1: a segment scoring below this is dropped.
    var scoreThreshold: Float = 0.5
    /// Step 2: of two segments overlapping by more than this (temporal IoU), the lower-scoring one
    /// is dropped, whatever their names.
    var suppressionOverlap: Float = 0.5
    /// Step 3: segments with the same names fewer than this many canonical frames apart are one.
    var mergeGapFrames = 5
    /// Step 4: a name scoring at least this is pre-filled.
    var prefillThreshold: Float = 0.5
    /// Step 5: the share of model-proposed clips drawn into the blind sample.
    var blindSampleRate = 0.1

    /// Steps 1–3, in video order. A merged segment spans both parts and takes the higher score
    /// of the two, and of each name's two scores: the merge bridges flicker inside one trick, so
    /// the trick is as sure as its surest part.
    func segments(from decoded: [TrickSegment]) -> [TrickSegment] {
        merged(suppressed(decoded.filter { $0.score >= scoreThreshold }))
    }

    /// Steps 4–6 for one surviving segment, made once, when its clip is created: the names that
    /// clear the pre-fill bar, and the blind draw.
    func proposal<Generator: RandomNumberGenerator>(
        for segment: TrickSegment, modelVersion: String, using generator: inout Generator
    ) -> ModelProposal {
        let confident = zip(segment.trickNames, segment.nameScores).filter { $0.1 >= prefillThreshold }.map(\.0)
        return ModelProposal(
            modelVersion: modelVersion, suggestedNames: confident,
            suggestionsWithheld: Double.random(in: 0..<1, using: &generator) < blindSampleRate)
    }

    private func suppressed(_ segments: [TrickSegment]) -> [TrickSegment] {
        var kept: [TrickSegment] = []
        let ranked = segments.sorted { ($1.score, $0.startFrame) < ($0.score, $1.startFrame) }
        for segment in ranked where kept.allSatisfy({ Self.overlap($0, segment) <= suppressionOverlap }) {
            kept.append(segment)
        }
        return kept
    }

    private func merged(_ segments: [TrickSegment]) -> [TrickSegment] {
        var result: [TrickSegment] = []
        for segment in segments.sorted(by: { ($0.startFrame, $0.endFrame) < ($1.startFrame, $1.endFrame) }) {
            guard let index = result.lastIndex(where: { $0.trickNames == segment.trickNames }),
                  segment.startFrame - result[index].endFrame < mergeGapFrames
            else {
                result.append(segment)
                continue
            }
            var union = result[index]
            union.endFrame = max(union.endFrame, segment.endFrame)
            union.score = max(union.score, segment.score)
            union.nameScores = zip(union.nameScores, segment.nameScores).map { max($0, $1) }
            result[index] = union
        }
        return result
    }

    /// Temporal intersection over union of two segments' frame ranges.
    static func overlap(_ lhs: TrickSegment, _ rhs: TrickSegment) -> Float {
        let intersection = max(0, min(lhs.endFrame, rhs.endFrame) - max(lhs.startFrame, rhs.startFrame))
        let union = (lhs.endFrame - lhs.startFrame) + (rhs.endFrame - rhs.startFrame) - intersection
        return union > 0 ? Float(intersection) / Float(union) : 0
    }
}

/// What the trick model proposes over one person's pose: each clip's window with how it was
/// proposed, in video order, and the run's embeddings.
struct TrickModelProposals: Sendable {
    let clips: [(window: TrickWindow, proposal: ModelProposal)]
    let embeddings: WindowEmbeddings?
}

extension TrickModel {
    /// Runs the model once over `frames`, one person's scored frames, and turns what it finds
    /// into proposals: §3.3's rules, then each surviving segment's names and blind draw. Frames
    /// too few to lay on a grid, or shorter than one window, propose nothing.
    func proposals<Generator: RandomNumberGenerator>(
        over frames: [PoseFrameResult], duration: TimeInterval?, personID: Int?,
        rules: TrickProposalRules, using generator: inout Generator
    ) throws -> TrickModelProposals {
        guard let input = TrickModelInput(frames: frames, duration: duration), let output = try run(input) else {
            return TrickModelProposals(clips: [], embeddings: nil)
        }
        let clips = rules.segments(from: output.segments).map {
            ($0.window, rules.proposal(for: $0, modelVersion: version, using: &generator))
        }
        let embeddings = output.embeddings.map {
            WindowEmbeddings(
                personID: personID, modelVersion: version, windowFrames: descriptor.windowFrames,
                windowStride: descriptor.windowStride, rows: $0)
        }
        return TrickModelProposals(clips: clips, embeddings: embeddings)
    }
}
