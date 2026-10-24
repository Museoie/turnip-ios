import CoreGraphics
import Foundation

/// Links the people the pose model finds in each frame into people followed across a take
/// (`docs/MULTI_PERSON.md` "Tracking"). Runs once over a take's frames, after sampling or at the
/// camera's hand-off, never per frame on the capture path.
///
/// Each frame's people are matched to the tracks still alive, best match first: by how much their
/// boxes overlap, then, for anyone overlap left unclaimed, by how far a person could have moved
/// since the track was last seen. Anyone still unclaimed starts a track of their own.
struct PersonTracker: Sendable {
    /// Box overlap, as intersection over union, that a match needs. The reference
    /// implementation's own box tracker uses 0.15.
    var minimumOverlap = 0.15
    /// How far an unclaimed person may be from where a track was last seen, in body sizes:
    /// `reachBase + reachPerSecond × seconds since`. Without it, a flip carries a far athlete
    /// further between two samples than their boxes overlap, and the trick splits across two
    /// tracks.
    var reachBase = 0.5
    var reachPerSecond = 3.0
    /// A track ends once its person has gone unseen for longer than this. A longer gap would
    /// re-link someone who walks out of frame and back, but it also hands a track from one person
    /// to another at the same spot, and crowds are what following everyone is for.
    var maximumGap: TimeInterval = 1

    /// Every person found in `frames`, in the order they first appeared. `renderedPixelSize` is
    /// what the frame-normalized boxes are measured against, so a distance means the same thing
    /// across a portrait frame as down it.
    func tracks(in frames: [MultiPoseFrame], renderedPixelSize: CGSize) -> [PoseTrack] {
        var open: [OpenTrack] = []
        for (position, frame) in frames.enumerated() {
            for index in open.indices where !open[index].isClosed
                && frame.timestamp - open[index].lastSeen > maximumGap + 1e-6 {
                open[index].isClosed = true
            }
            let live = open.indices.filter { !open[$0].isClosed }
            var claimedPeople = Set<Int>()
            var claimedTracks = Set<Int>()

            func claim(_ person: Int, by track: Int) {
                claimedPeople.insert(person)
                claimedTracks.insert(track)
                open[track].see(frame.people[person], at: position, time: frame.timestamp)
            }

            for match in overlapMatches(frame.people, live: live, open: open)
            where !claimedPeople.contains(match.person) && !claimedTracks.contains(match.track) {
                claim(match.person, by: match.track)
            }
            let unclaimedLive = live.filter { !claimedTracks.contains($0) }
            for match in reachMatches(
                in: frame, excluding: claimedPeople, live: unclaimedLive, open: open, pixelSize: renderedPixelSize)
            where !claimedPeople.contains(match.person) && !claimedTracks.contains(match.track) {
                claim(match.person, by: match.track)
            }
            for person in frame.people.indices where !claimedPeople.contains(person) {
                var track = OpenTrack(id: open.count, lastSeen: frame.timestamp, box: frame.people[person].box)
                track.see(frame.people[person], at: position, time: frame.timestamp)
                open.append(track)
            }
        }
        return open.map { $0.track(over: frames) }
    }

    /// A possible match: a person in the frame, a track, and how good a match they are.
    private struct Candidate {
        let measure: Double
        let person: Int
        let track: Int
    }

    /// Person–track pairs whose boxes overlap enough, best first. Ties go to the later person and
    /// then the later track, which keeps the order fully determined.
    private func overlapMatches(_ people: [DetectedPerson], live: [Int], open: [OpenTrack]) -> [Candidate] {
        var candidates: [Candidate] = []
        for person in people.indices {
            for track in live {
                let overlap = Self.overlap(people[person].box, open[track].box)
                if overlap >= minimumOverlap {
                    candidates.append(Candidate(measure: overlap, person: person, track: track))
                }
            }
        }
        return candidates.sorted { ($0.measure, $0.person, $0.track) > ($1.measure, $1.person, $1.track) }
    }

    /// Unclaimed person–track pairs within reach, nearest first.
    private func reachMatches(
        in frame: MultiPoseFrame, excluding claimed: Set<Int>, live: [Int], open: [OpenTrack], pixelSize: CGSize
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for person in frame.people.indices where !claimed.contains(person) {
            for track in live {
                let distance = Self.distanceInBodySizes(
                    frame.people[person].box, open[track].box, pixelSize: pixelSize)
                if distance <= reachBase + reachPerSecond * (frame.timestamp - open[track].lastSeen) {
                    candidates.append(Candidate(measure: distance, person: person, track: track))
                }
            }
        }
        return candidates.sorted { ($0.measure, $0.person, $0.track) < ($1.measure, $1.person, $1.track) }
    }

    /// Intersection over union. Scaling an axis scales both areas alike, so frame-normalized boxes
    /// give the same answer pixels would.
    static func overlap(_ first: NormalizedRect, _ second: NormalizedRect) -> Double {
        let width = max(0, Double(min(first.maxX, second.maxX) - max(first.minX, second.minX)))
        let height = max(0, Double(min(first.maxY, second.maxY) - max(first.minY, second.minY)))
        let intersection = width * height
        let union = Double(first.width * first.height + second.width * second.height) - intersection
        return union > 0 ? intersection / union : 0
    }

    /// The distance between two boxes' centres, in units of the longest side of either box, in
    /// pixels: a person's own size, so the same move reads the same near the camera or far from it.
    static func distanceInBodySizes(_ first: NormalizedRect, _ second: NormalizedRect, pixelSize: CGSize) -> Double {
        let width = Double(pixelSize.width)
        let height = Double(pixelSize.height)
        let dx = Double((first.minX + first.maxX) - (second.minX + second.maxX)) / 2 * width
        let dy = Double((first.minY + first.maxY) - (second.minY + second.maxY)) / 2 * height
        let size = max(
            Double(second.width) * width, Double(second.height) * height,
            Double(first.width) * width, Double(first.height) * height)
        return (dx * dx + dy * dy).squareRoot() / max(size, 1e-6)
    }
}

/// A track while the take is being walked: where its person was last seen, and every frame they
/// were seen in.
private struct OpenTrack {
    let id: Int
    var lastSeen: TimeInterval
    var box: NormalizedRect
    var isClosed = false
    /// Frame position in the take → that frame's sighting.
    var sightings: [Int: DetectedPerson] = [:]

    mutating func see(_ person: DetectedPerson, at position: Int, time: TimeInterval) {
        sightings[position] = person
        lastSeen = time
        box = person.box
    }

    /// The person's pose from their first sighting to their last, empty where unseen in between.
    func track(over frames: [MultiPoseFrame]) -> PoseTrack {
        let positions = sightings.keys
        guard let first = positions.min(), let last = positions.max() else {
            return PoseTrack(id: id, frames: [])
        }
        return PoseTrack(id: id, frames: (first...last).map { position in
            PoseFrameResult(
                frameIndex: frames[position].frameIndex,
                timestamp: frames[position].timestamp,
                keypoints: sightings[position]?.keypoints ?? [])
        })
    }
}
