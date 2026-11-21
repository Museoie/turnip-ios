import CoreGraphics
import Foundation

/// The pose Auto follow fits a person's clip to (`docs/MULTI_PERSON.md` "Auto follow"): the
/// person's own track, with the stretches where it has nothing filled in from the take's other
/// poses.
///
/// A track runs from its person's first sighting to their last, so any part of the clip's
/// window outside that, a trim pulled out past it or a track that started partway through
/// because the tracker lost the athlete for a moment, has no pose at all, and inside it a
/// frame where the tracker didn't see them is empty. Auto follow holds the crop still over
/// every such frame, at the framing of the nearest one it does know, so a clip whose first
/// half falls outside the track never follows the athlete there. Here those frames take the
/// pose of whoever, in the other poses at that frame, is nearest where the person was last
/// seen and within reach of it, walking out from the track in both directions, the way the
/// tracker links a person from frame to frame (`PersonTracker`). The reach is the tracker's,
/// and the gap it bridges is longer: a framing that follows the wrong person for a moment
/// costs less than one that stops following, and only frames the track itself has nothing
/// for are filled.
///
/// The other poses are what a run keeps: the pose the model was surest of in every frame,
/// and the tracks of the other people who own a clip. Someone the model found in neither, a
/// bystander it was less sure of than the athlete, can't be borrowed from.
enum FollowPose {
    /// How far a sighting may be from where the person was last seen, in body sizes:
    /// `reachBase + reachPerSecond × seconds since`, as the tracker measures it.
    static let reachBase = PersonTracker().reachBase
    static let reachPerSecond = PersonTracker().reachPerSecond
    /// How long the person may go without any sighting before the walk stops: twice the
    /// tracker's, since a stretch Auto follow can't follow is the failure this exists for.
    static let maximumGap: TimeInterval = 2
    /// The fewest located joints a borrowed sighting needs: one stray joint is not a person.
    static let minimumJoints = 3

    /// `own`, the person's track, filled in from `others` (each a sequence of pose frames, in
    /// any order), measured in a frame of `renderedPixelSize`. In time order, from the first
    /// frame anything was found for to the last; `own` unchanged when it locates nothing, so
    /// there is nowhere to start from, or when the frame size is unknown.
    static func frames(
        of own: [PoseFrameResult], borrowingFrom others: [[PoseFrameResult]], renderedPixelSize: CGSize
    ) -> [PoseFrameResult] {
        guard renderedPixelSize.width > 0, renderedPixelSize.height > 0, !others.isEmpty else { return own }
        var timestamps: [Int: TimeInterval] = [:]
        var sightings: [Int: [Sighting]] = [:]
        for frame in others.joined() {
            timestamps[frame.frameIndex] = frame.timestamp
            if let sighting = Sighting(frame.keypoints, minimumJoints: minimumJoints) {
                sightings[frame.frameIndex, default: []].append(sighting)
            }
        }
        var ownSightings: [Int: Sighting] = [:]
        for frame in own {
            timestamps[frame.frameIndex] = frame.timestamp
            if let sighting = Sighting(frame.keypoints, minimumJoints: 1) {
                ownSightings[frame.frameIndex] = sighting
            }
        }
        let timeline = timestamps.keys.sorted()
        guard let start = timeline.firstIndex(where: { ownSightings[$0] != nil }) else { return own }

        var found: [Int: [PoseKeypoint]] = [:]
        func walk(_ positions: [Int]) {
            var anchor: (box: NormalizedRect, time: TimeInterval)?
            for position in positions {
                let index = timeline[position], time = timestamps[index] ?? 0
                if let sighting = ownSightings[index] {
                    found[index] = sighting.keypoints
                    anchor = (sighting.box, time)
                    continue
                }
                guard let last = anchor else { continue }
                // Past the gap, nothing more is borrowed until the track itself sees them again.
                let elapsed = abs(time - last.time)
                guard elapsed <= maximumGap + 1e-6 else { continue }
                let reach = reachBase + reachPerSecond * elapsed
                let nearest = (sightings[index] ?? [])
                    .map { ($0, PersonTracker.distanceInBodySizes($0.box, last.box, pixelSize: renderedPixelSize)) }
                    .filter { $0.1 <= reach }
                    .min { $0.1 < $1.1 }
                if let (sighting, _) = nearest {
                    found[index] = sighting.keypoints
                    anchor = (sighting.box, time)
                }
            }
        }
        walk(Array(start..<timeline.count))
        walk(Array((0...start).reversed()))

        let located = timeline.filter { found[$0] != nil }
        guard let first = located.first, let last = located.last else { return own }
        return timeline.filter { $0 >= first && $0 <= last }.map { index in
            PoseFrameResult(frameIndex: index, timestamp: timestamps[index] ?? 0, keypoints: found[index] ?? [])
        }
    }

    /// One person's pose in one frame, with the box around their located joints.
    private struct Sighting {
        let keypoints: [PoseKeypoint]
        let box: NormalizedRect

        init?(_ keypoints: [PoseKeypoint], minimumJoints: Int) {
            let points = CropRectCalculator.locatedPoints(
                in: [PoseFrameResult(frameIndex: 0, timestamp: 0, keypoints: keypoints)])
            guard points.count >= minimumJoints,
                  let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
            else { return nil }
            self.keypoints = keypoints
            box = NormalizedRect(minX: Float(minX), maxX: Float(maxX), minY: Float(minY), maxY: Float(maxY))
        }
    }
}
