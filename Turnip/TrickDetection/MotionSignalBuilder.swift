import Foundation

/// Which keypoint group produced an anchor.
///
/// Displacement is only measured between two frames anchored on the same group: a hip midpoint
/// and a shoulder/nose midpoint sit a torso apart, so differencing across the two reports that
/// fixed offset as athlete motion — a spike several times the peak-detection threshold.
enum MotionAnchorSource: Equatable, Sendable {
    case hips
    case upperBody
}

/// The single normalized point a frame's 17 keypoints collapse to.
struct MotionAnchor: Equatable, Sendable {
    let x: Float
    let y: Float
    let source: MotionAnchorSource
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

    static func buildSignal(from frames: [PoseFrameResult]) -> [MotionSample] {
        smoothed(displacements(across: frames, anchoredAt: anchors(for: frames)))
    }

    /// Resolves one anchor per frame, applying the design doc's blur mitigations in the order
    /// that keeps the anchor group stable: a one-frame hip dropout is bridged from its hip
    /// neighbours first, so the upper-body fallback only takes over stretches the hips lose
    /// outright rather than flip-flopping across isolated frames.
    static func anchors(for frames: [PoseFrameResult]) -> [MotionAnchor?] {
        var resolved = frames.map { midpoint(of: hipKeypointNames, in: $0, source: .hips) }
        resolved = interpolatingSingleFrameGaps(in: resolved)

        for index in resolved.indices where resolved[index] == nil {
            resolved[index] = midpoint(of: upperBodyKeypointNames, in: frames[index], source: .upperBody)
        }
        return interpolatingSingleFrameGaps(in: resolved)
    }

    private static func midpoint(
        of names: Set<String>,
        in frame: PoseFrameResult,
        source: MotionAnchorSource
    ) -> MotionAnchor? {
        let usable = frame.keypoints.filter {
            names.contains($0.name) && $0.confidence > PoseKeypoint.confidenceThreshold
        }
        guard !usable.isEmpty else { return nil }

        let count = Float(usable.count)
        return MotionAnchor(
            x: usable.reduce(0) { $0 + $1.x } / count,
            y: usable.reduce(0) { $0 + $1.y } / count,
            source: source
        )
    }

    /// Estimates a missing anchor as the average of its neighbours. Reads every neighbour from
    /// the input rather than from the partly-filled output, so an estimate never seeds the next
    /// estimate and only genuine one-frame gaps close.
    private static func interpolatingSingleFrameGaps(in anchors: [MotionAnchor?]) -> [MotionAnchor?] {
        var filled = anchors
        for index in anchors.indices.dropFirst().dropLast() where anchors[index] == nil {
            guard let previous = anchors[index - 1],
                  let next = anchors[index + 1],
                  previous.source == next.source else { continue }
            filled[index] = MotionAnchor(
                x: (previous.x + next.x) / 2,
                y: (previous.y + next.y) / 2,
                source: previous.source
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
        guard let origin, let destination, origin.source == destination.source else { return nil }
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
