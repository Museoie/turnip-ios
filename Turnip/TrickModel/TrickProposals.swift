import Foundation
import os

/// How the trick model proposed a clip (`MODEL_CONTRACT.md` §3.3 steps 5–6): the model, the names
/// it pre-filled, or on a blind clip would have, the names that scored below the pre-fill bar, and
/// whether the clip is in the blind sample. The clip keeps it whatever the user does with the
/// names or the window, and sends it with the clip if it is contributed, so training can tell
/// which names were kept from the model.
struct ModelProposal: Codable, Hashable, Sendable {
    let modelVersion: String
    let suggestedNames: [String]
    /// The model's names for the clip that scored below the pre-fill bar, surest first
    /// (`docs/PERSONALIZATION_DESIGN.md` §4.2 tier 3): never pre-filled, shown as suggestions
    /// instead. `[]` for clips saved before this was recorded.
    let belowBarNames: [String]
    let suggestionsWithheld: Bool

    init(
        modelVersion: String, suggestedNames: [String], belowBarNames: [String] = [],
        suggestionsWithheld: Bool
    ) {
        self.modelVersion = modelVersion
        self.suggestedNames = suggestedNames
        self.belowBarNames = belowBarNames
        self.suggestionsWithheld = suggestionsWithheld
    }

    private enum CodingKeys: String, CodingKey {
        case modelVersion, suggestedNames, belowBarNames, suggestionsWithheld
    }

    /// Clips saved before tier 3 was recorded carry no `belowBarNames` key; they decode to `[]`
    /// instead of failing the whole library load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelVersion = try container.decode(String.self, forKey: .modelVersion)
        suggestedNames = try container.decode([String].self, forKey: .suggestedNames)
        belowBarNames = try container.decodeIfPresent([String].self, forKey: .belowBarNames) ?? []
        suggestionsWithheld = try container.decode(Bool.self, forKey: .suggestionsWithheld)
    }

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
    /// The grid the rows sit on, and the classes `probabilities`' columns are.
    let descriptor: TrickModelDescriptor
    /// Row `i` covers canonical frames `[i × windowStride, i × windowStride + windowFrames)`.
    let rows: [[Float]]
    /// `window_probs` on the same grid: what the central model makes of each window, which the
    /// personal layer's gate measures itself against (`docs/PERSONALIZATION_DESIGN.md` §5).
    let probabilities: [[Float]]
}

/// The client's postprocessing of the model's segments (`MODEL_CONTRACT.md` §3.3, normative).
struct TrickProposalRules: Sendable {
    /// Step 1: a segment scoring below this is dropped.
    var scoreThreshold: Float = 0.5
    /// Step 1's band: a personal keep layer that has passed its gate decides the segments scoring
    /// inside it, and only those (`MODEL_CONTRACT.md` §3.5).
    static let personalBand: Range<Float> = 0.3..<0.7
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
    ///
    /// `keep` is the personal keep layer's decision for a segment in `personalBand`, `nil` where it
    /// can't decide one; without it, and for every segment outside the band, step 1 is the
    /// threshold.
    func segments(
        from decoded: [TrickSegment], keeping keep: ((TrickSegment) -> Bool?)? = nil
    ) -> [TrickSegment] {
        merged(suppressed(decoded.filter { passesStepOne($0, keeping: keep) }))
    }

    /// Step 1 for one segment.
    func passesStepOne(_ segment: TrickSegment, keeping keep: ((TrickSegment) -> Bool?)?) -> Bool {
        guard Self.personalBand.contains(segment.score), let decided = keep?(segment) else {
            return segment.score >= scoreThreshold
        }
        return decided
    }

    /// Steps 4–6 for one surviving segment, made once, when its clip is created: the names that
    /// clear the pre-fill bar, the names below it kept in score order for tier 3, and the blind
    /// draw.
    func proposal<Generator: RandomNumberGenerator>(
        for segment: TrickSegment, modelVersion: String, using generator: inout Generator
    ) -> ModelProposal {
        let scored = zip(segment.trickNames, segment.nameScores)
        let confident = scored.filter { $0.1 >= prefillThreshold }.map(\.0)
        let belowBar = scored.filter { $0.1 < prefillThreshold }
            .sorted { $0.1 > $1.1 }.map(\.0)
        return ModelProposal(
            modelVersion: modelVersion, suggestedNames: confident, belowBarNames: belowBar,
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

/// One clip the trick model proposes: its window, the canonical frames it was proposed over, and
/// how it was proposed.
struct ProposedClip: Sendable {
    let window: TrickWindow
    let frames: Range<Int>
    let proposal: ModelProposal
}

/// What the trick model proposes over one person's pose: its clips, in video order, and the run's
/// embeddings.
struct TrickModelProposals: Sendable {
    let clips: [ProposedClip]
    let embeddings: WindowEmbeddings?
}

/// The trick model an analysis proposes with, and the personal keep layer that decides its band
/// (`docs/PERSONALIZATION_DESIGN.md` §4.3), `nil` when the layer is off. One value, so no caller
/// can hand detection the model and leave the layer behind.
struct TrickProposer: Sendable {
    let model: TrickModel
    let keepLayer: PersonalKeepLayer?

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "Personalization")

    /// Runs the model once over `frames`, one person's scored frames, and turns what it finds
    /// into proposals: §3.3's rules, then each surviving segment's names and blind draw. Frames
    /// too few to lay on a grid, or shorter than one window, propose nothing.
    ///
    /// A keep layer fit under this model decides step 1's band, from each segment's embedding.
    /// Everything after step 1 is the same either way: the blind draw is made on every proposal
    /// however it passed, and its names are the central ones.
    func proposals<Generator: RandomNumberGenerator>(
        over frames: [PoseFrameResult], duration: TimeInterval?, personID: Int?,
        rules: TrickProposalRules, using generator: inout Generator
    ) throws -> TrickModelProposals {
        guard let input = TrickModelInput(frames: frames, duration: duration), let output = try model.run(input)
        else {
            return TrickModelProposals(clips: [], embeddings: nil)
        }
        let embeddings = model.windowEmbeddings(of: output, personID: personID)
        let keep = embeddings?.keepDecision(by: keepLayer)
        if keep != nil {
            let band = output.segments.filter { TrickProposalRules.personalBand.contains($0.score) }
            let kept = band.filter { rules.passesStepOne($0, keeping: keep) }.count
            Self.logger.notice("Keep layer decided \(band.count) band segments, kept \(kept)")
        }
        let clips = rules.segments(from: output.segments, keeping: keep).map {
            ProposedClip(
                window: $0.window, frames: $0.startFrame..<$0.endFrame,
                proposal: rules.proposal(for: $0, modelVersion: model.version, using: &generator))
        }
        return TrickModelProposals(clips: clips, embeddings: embeddings)
    }
}

extension TrickModel {
    /// A run's embeddings as the personal layer reads them; `nil` for a model without them.
    func windowEmbeddings(of output: TrickModelOutput, personID: Int?) -> WindowEmbeddings? {
        output.embeddings.map {
            WindowEmbeddings(
                personID: personID, modelVersion: version, descriptor: descriptor, rows: $0,
                probabilities: output.windowProbabilities)
        }
    }
}
