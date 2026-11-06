import Foundation

/// One scored person with the model's numbers and nothing else: the score, the box, and the
/// keypoints as flat floats in COCO order — (y, x, confidence) per joint, the order MoveNet
/// emits them and the order `PoseKeypoint.names` lists them in. No per-keypoint UUID or name:
/// the name of joint `i` is `PoseKeypoint.names[i]`, so storing it per frame would repeat the
/// same 17 strings 10 times a second. A packed person is ~224 bytes (score + box + 51 floats)
/// against ~900 for the rich `DetectedPerson` it unpacks to.
struct PackedPosePerson: Hashable, Sendable {
    let score: Float
    let box: NormalizedRect
    /// 3 floats per joint — (y, x, confidence) — in `PoseKeypoint.names` order. Any count is
    /// representable (fixtures carry a single joint); production frames always carry 17.
    let keypoints: [Float]

    /// The decode path: rebuilds a packed person from values read off the file.
    init(score: Float, box: NormalizedRect, keypoints: [Float]) {
        self.score = score
        self.box = box
        self.keypoints = keypoints
    }

    init(_ person: DetectedPerson) {
        score = person.score
        box = person.box
        keypoints = person.keypoints.flatMap { [$0.y, $0.x, $0.confidence] }
    }

    /// Rebuilds the rich person. Keypoints get fresh UUIDs: identity is not part of the packed
    /// form, and nothing downstream compares keypoint identity across the store — detection
    /// compares values (windows, crop rects), and the overlay reads the live rich frames,
    /// never the stored ones.
    func unpack() -> DetectedPerson {
        let keypoints = (0..<(keypoints.count / 3)).map { index in
            let base = index * 3
            return PoseKeypoint(
                name: index < PoseKeypoint.names.count
                    ? PoseKeypoint.names[index] : "keypoint-\(index)",
                y: keypoints[base],
                x: keypoints[base + 1],
                confidence: keypoints[base + 2])
        }
        return DetectedPerson(score: score, box: box, keypoints: keypoints)
    }
}

/// One scored frame in packed form: the frame's place on the take's timeline plus every person
/// the model found, as flat floats. ~250 bytes with one person against ~1.8 KB for the rich
/// `MultiPoseFrame` (whose primary repeats the most-confident person's keypoints). The frame
/// index and timestamp ride along so unpacking restores the exact frame the model scored.
struct PackedPoseFrame: Hashable, Sendable {
    let frameIndex: Int
    let timestamp: TimeInterval
    let people: [PackedPosePerson]

    /// The decode path: rebuilds a packed frame from values read off the file.
    init(frameIndex: Int, timestamp: TimeInterval, people: [PackedPosePerson]) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.people = people
    }

    init(_ frame: MultiPoseFrame) {
        frameIndex = frame.frameIndex
        timestamp = frame.timestamp
        people = frame.people.map(PackedPosePerson.init)
    }

    /// Rebuilds the rich frame. The primary is re-derived from the most-confident person,
    /// exactly as `MultiPoseFrame.init(frameIndex:timestamp:people:)` does, so the unpacked
    /// frame holds the same values as the packed one.
    func unpack() -> MultiPoseFrame {
        MultiPoseFrame(frameIndex: frameIndex, timestamp: timestamp, people: people.map { $0.unpack() })
    }
}
