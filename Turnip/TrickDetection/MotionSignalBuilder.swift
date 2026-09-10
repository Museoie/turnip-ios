import Foundation

/// Which keypoint group produced an anchor.
///
/// Displacement is only measured between two frames anchored on the same group: a hip midpoint
/// and a shoulder/nose midpoint sit a torso apart, so differencing across the two reports that
/// fixed offset as athlete motion — a spike several times the peak-detection threshold.
///
/// The offset problem exists *within* a group too: a two-hip midpoint and a lone left hip both
/// read `.hips`, but sit a half hip-width apart. The anchor's `members` carry its identity
/// inside the group so the comparability checks refuse those pairs.
enum MotionAnchorSource: Equatable, Sendable {
    case hips
    case upperBody
}

/// The single normalized point a frame's 17 keypoints collapse to.
struct MotionAnchor: Equatable, Sendable {
    let x: Float
    let y: Float
    let source: MotionAnchorSource
    /// The keypoint names actually averaged — the anchor's identity within its group.
    /// A reconstructed anchor carries the full group: it estimates the full-group midpoint,
    /// so it is comparable with genuine full-group anchors.
    let members: Set<String>
}

/// One frame-to-frame anchor displacement, in normalized units.
struct MotionSample: Equatable, Sendable {
    /// Timestamp of the earlier frame of the pair.
    let startTime: TimeInterval
    /// Timestamp of the later frame of the pair.
    let endTime: TimeInterval
    /// `nil` when the pair had no comparable anchor at both ends. Motion is *unknown* there
    /// rather than zero, and peak detection distinguishes the two.
    let displacement: Float?
}

/// Collapses per-frame pose output into the 1D motion signal peak detection runs on
/// (docs/DESIGN.md's pipeline step 4).
enum MotionSignalBuilder {
    static let hipKeypointNames: Set<String> = ["left_hip", "right_hip"]
    /// Bigger, blur-resistant targets that carry the anchor while the hips are unusable.
    static let upperBodyKeypointNames: Set<String> = ["left_shoulder", "right_shoulder", "nose"]

    private static let smoothingRadius = 1

    /// How far back a partial-group frame may reach for the most recent full-group frame when
    /// reconstructing its midpoint. The projected body geometry the correction is measured from
    /// — e.g. the hip half-vector — is near-constant over a few frames, but it can rotate fast
    /// mid-trick, which is exactly where motion blur concentrates; a stale correction would
    /// fabricate stillness. Past this bound the frame keeps its partial identity and its
    /// displacement stays unknown.
    private static let reconstructionLookbackFrames = 3

    static func buildSignal(from frames: [PoseFrameResult]) -> [MotionSample] {
        smoothed(displacements(across: frames, anchoredAt: anchors(for: frames)))
    }

    /// Resolves one anchor per frame, applying the design doc's blur mitigations in the order
    /// that keeps the anchor group stable: a one-frame hip dropout is bridged from its hip
    /// neighbours first, so the upper-body fallback only takes over stretches the hips lose
    /// outright rather than flip-flopping across isolated frames.
    static func anchors(for frames: [PoseFrameResult]) -> [MotionAnchor?] {
        var resolved = resolveAnchors(for: frames, group: hipKeypointNames, source: .hips)
        resolved = interpolatingSingleFrameGaps(in: resolved)

        let upperBody = resolveAnchors(for: frames, group: upperBodyKeypointNames, source: .upperBody)
        for index in resolved.indices where resolved[index] == nil {
            resolved[index] = upperBody[index]
        }
        return interpolatingSingleFrameGaps(in: resolved)
    }

    /// One anchor per frame for a single keypoint group, in frame order.
    ///
    /// A frame whose whole group clears confidence anchors on the true midpoint and records the
    /// frame's keypoint geometry. A frame where only part of the group clears reconstructs the
    /// full-group midpoint from the most recent full-group frame when one is close enough —
    /// motion blur drops keypoints exactly during the fast frames the pipeline exists to find,
    /// so degrading to the lone point's position would report a fixed body offset as athlete
    /// motion (issue #58). With no recent full-group frame the anchor keeps its partial
    /// identity, and the comparability checks below leave its displacement unknown.
    private static func resolveAnchors(
        for frames: [PoseFrameResult],
        group: Set<String>,
        source: MotionAnchorSource
    ) -> [MotionAnchor?] {
        var resolved = [MotionAnchor?]()
        resolved.reserveCapacity(frames.count)
        var lastFullGroup: (index: Int, positions: [String: (x: Float, y: Float)])?
        for (index, frame) in frames.enumerated() {
            let usable = frame.keypoints.filter {
                group.contains($0.name) && $0.confidence > PoseKeypoint.confidenceThreshold
            }
            guard !usable.isEmpty else {
                resolved.append(nil)
                continue
            }
            if usable.count == group.count {
                lastFullGroup = (
                    index,
                    Dictionary(uniqueKeysWithValues: usable.map { ($0.name, ($0.x, $0.y)) })
                )
                resolved.append(anchor(averaging: usable, members: group, source: source))
            } else if let snapshot = lastFullGroup,
                      index - snapshot.index <= reconstructionLookbackFrames {
                resolved.append(reconstructedAnchor(
                    usable: usable, group: group, source: source, snapshot: snapshot
                ))
            } else {
                // No recent full-group frame: keep the partial identity. distance(from:to:)
                // only compares identical member sets, so this anchor's displacement stays
                // unknown rather than measuring the offset between two different body points.
                resolved.append(anchor(
                    averaging: usable,
                    members: Set(usable.map(\.name)),
                    source: source
                ))
            }
        }
        return resolved
    }

    private static func anchor(
        averaging keypoints: [PoseKeypoint],
        members: Set<String>,
        source: MotionAnchorSource
    ) -> MotionAnchor {
        let count = Float(keypoints.count)
        return MotionAnchor(
            x: keypoints.reduce(0) { $0 + $1.x } / count,
            y: keypoints.reduce(0) { $0 + $1.y } / count,
            source: source,
            members: members
        )
    }

    /// Estimates the full-group midpoint for a partial frame. The offset between the full-group
    /// midpoint and the mean of the *currently usable* members is measured on the most recent
    /// full-group frame — where the projected body geometry is near-constant over a few frames —
    /// and applied to the usable members' mean now, so the anchor stays on the body centerline
    /// instead of jumping to the lone point. For the hips this is the issue's half-vector
    /// estimate; the same arithmetic covers asymmetric groups like the upper body.
    private static func reconstructedAnchor(
        usable: [PoseKeypoint],
        group: Set<String>,
        source: MotionAnchorSource,
        snapshot: (index: Int, positions: [String: (x: Float, y: Float)])
    ) -> MotionAnchor {
        let usableNames = Set(usable.map(\.name))
        let snapshotSubset = snapshot.positions.filter { usableNames.contains($0.key) }.map { $0.value }
        let snapshotSubsetMean = mean(snapshotSubset)
        let snapshotFullMean = mean(Array(snapshot.positions.values))
        let nowMean = mean(usable.map { ($0.x, $0.y) })
        // The reconstructed point estimates the full-group midpoint, so it carries the full
        // group's identity and compares against genuine full-group anchors.
        return MotionAnchor(
            x: nowMean.x + (snapshotFullMean.x - snapshotSubsetMean.x),
            y: nowMean.y + (snapshotFullMean.y - snapshotSubsetMean.y),
            source: source,
            members: group
        )
    }

    private static func mean(_ points: [(x: Float, y: Float)]) -> (x: Float, y: Float) {
        let count = Float(points.count)
        return (
            points.reduce(0) { $0 + $1.x } / count,
            points.reduce(0) { $0 + $1.y } / count
        )
    }

    /// Estimates a missing anchor as the average of its neighbours. Reads every neighbour from
    /// the input rather than from the partly-filled output, so an estimate never seeds the next
    /// estimate and only genuine one-frame gaps close. Neighbours must share anchor identity,
    /// not just the group: interpolating between a two-hip midpoint and a lone hip would bake
    /// half the fixed offset into the estimate.
    private static func interpolatingSingleFrameGaps(in anchors: [MotionAnchor?]) -> [MotionAnchor?] {
        var filled = anchors
        for index in anchors.indices.dropFirst().dropLast() where anchors[index] == nil {
            guard let previous = anchors[index - 1],
                  let next = anchors[index + 1],
                  previous.source == next.source,
                  previous.members == next.members else { continue }
            filled[index] = MotionAnchor(
                x: (previous.x + next.x) / 2,
                y: (previous.y + next.y) / 2,
                source: previous.source,
                members: previous.members
            )
        }
        return filled
    }

    private static func displacements(
        across frames: [PoseFrameResult],
        anchoredAt anchors: [MotionAnchor?]
    ) -> [MotionSample] {
        frames.indices.dropFirst().map { index in
            MotionSample(
                startTime: frames[index - 1].timestamp,
                endTime: frames[index].timestamp,
                displacement: distance(from: anchors[index - 1], to: anchors[index])
            )
        }
    }

    private static func distance(from origin: MotionAnchor?, to destination: MotionAnchor?) -> Float? {
        // Identity, not just the group, must match: a two-hip midpoint and a lone left hip both
        // read `.hips`, but differencing across the two reports a half hip-width of fixed offset
        // as athlete motion (issue #58).
        guard let origin, let destination,
              origin.source == destination.source,
              origin.members == destination.members else { return nil }
        let dx = destination.x - origin.x
        let dy = destination.y - origin.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 3-sample moving average over the samples that have a value. A gap stays a gap: averaging
    /// it away would hand peak detection a fabricated displacement for a frame pair where the
    /// athlete was never located.
    private static func smoothed(_ samples: [MotionSample]) -> [MotionSample] {
        samples.indices.map { index in
            let sample = samples[index]
            guard sample.displacement != nil else { return sample }

            let lower = max(samples.startIndex, index - smoothingRadius)
            let upper = min(samples.endIndex - 1, index + smoothingRadius)
            let present = samples[lower...upper].compactMap(\.displacement)
            return MotionSample(
                startTime: sample.startTime,
                endTime: sample.endTime,
                displacement: present.reduce(0, +) / Float(present.count)
            )
        }
    }
}
