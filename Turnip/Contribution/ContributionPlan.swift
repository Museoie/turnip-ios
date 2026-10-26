import Foundation

/// What a contribution of one video's saved, toggled clips would send, worked out before
/// anything is sent so the confirmation sheet can show it (`docs/CONTRIBUTION_DESIGN.md` §2.3,
/// §3.3).
///
/// The farm keeps one pose sequence per video, and a clip's pose is its own person's
/// (`docs/MULTI_PERSON.md` "Contribution, Profile and privacy"). So the sequence sent is the first
/// clip's person's, and a clip of anyone else in the same video stays behind rather than be sent
/// against a pose that isn't theirs. *(Judgment call: a second person's clips wait for a farm
/// shape that holds more than one track per video.)*
struct ContributionPlan {
    enum ClipStatus: Equatable {
        case ready
        /// A different person in the same video from the one whose pose is sent.
        case otherPerson
    }

    /// How well pose tracking followed the sent clips: the share of their frames with no pose.
    enum Quality: Equatable {
        case good
        /// Over 30% gaps: sent, with a warning.
        case patchy
        /// Over 60% gaps, or no pose at all: nothing is sent.
        case unusable
    }

    let clips: [(item: ClipListItem, status: ClipStatus)]
    let quality: Quality
    /// What the uploader sends; `nil` when nothing can be.
    let source: SourceContribution?

    static let patchyGapFraction = 0.3
    static let unusableGapFraction = 0.6

    init(
        clips items: [ClipListItem], videoID: String, duration: TimeInterval,
        poseFrames: (Int?) -> [PoseFrameResult]
    ) {
        let person = items.first?.personID
        clips = items.map { ($0, $0.personID == person ? .ready : .otherPerson) }
        let ready = items.filter { $0.personID == person }
        guard !ready.isEmpty, let pose = ContributionPose(frames: poseFrames(person), duration: duration) else {
            quality = .unusable
            source = nil
            return
        }
        let gaps = pose.gapFraction(in: ready.map(\.window))
        quality = gaps > Self.unusableGapFraction ? .unusable : gaps > Self.patchyGapFraction ? .patchy : .good
        source = quality == .unusable ? nil : SourceContribution(
            videoID: videoID, pose: pose,
            clips: ready.map {
                ClipContribution(clipID: $0.id, window: $0.window, autoDetected: $0.isAutoDetected, names: $0.names)
            })
    }

    var hasClips: Bool { !clips.isEmpty }
    /// Whether any clip is marked as someone other than the user: the sheet flags the consent line.
    var includesSomeoneElse: Bool { clips.contains { $0.status == .ready && !$0.item.isMe } }
}
