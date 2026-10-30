import Foundation

extension ContributionPose {
    /// The grid resampled onto the canonical 10 Hz timeline, frame `k` at `k / 10` seconds, the
    /// way the farm resamples a contributed blob on ingest (`POSE_FORMAT.md` §6): linear in x, y
    /// and confidence between the two grid slots around each canonical time, a gap wherever
    /// either of them is one, and a grid slot copied as it is when a canonical time lands on it.
    /// The arithmetic is the farm's, in doubles with its snap of near-integer positions, so the
    /// trick model reads the same canonical frames on device that it was trained on.
    var canonicalSlots: [[Float]?] {
        let rate = Double(sampleRate)
        guard rate != Double(Self.canonicalRate) else { return slots }
        return (0..<canonicalFrameCount).map { frame in
            var position = Double(frame) * rate / Double(Self.canonicalRate)
            let nearest = position.rounded()
            if abs(position - nearest) <= 1e-9 * max(1, abs(position)) {
                position = nearest
            }
            let index = Int(position.rounded(.down))
            let fraction = position - Double(index)
            guard slots.indices.contains(index) else { return nil }
            guard fraction != 0 else { return slots[index] }
            guard slots.indices.contains(index + 1),
                  let before = slots[index], let after = slots[index + 1]
            else { return nil }
            return zip(before, after).map { Float((1 - fraction) * Double($0) + fraction * Double($1)) }
        }
    }
}

/// The trick model's input (`MODEL_CONTRACT.md` §3.1, §3.4): the canonical 10 Hz frames as
/// `T × 52` float32, row-major, each row 17 × (x, y, confidence) in COCO order and then the gap
/// indicator. A gap row is all zeros with the indicator at 1, as the canonical blob stores a
/// gap. x and y stay as the pose model emitted them, in source-frame coordinates: where the
/// athlete is in the frame is part of what the model reads. Low-confidence keypoints stay in too,
/// with their confidence: the model trained on contributed pose, which records them as they were.
struct TrickModelInput: Equatable, Sendable {
    static let channels = ContributionPose.keypointCount * 3 + 1

    /// The number of canonical frames, `T`.
    let frameCount: Int
    /// `frameCount × channels` values, row-major.
    let values: [Float]

    init(canonicalSlots: [[Float]?]) {
        let width = ContributionPose.keypointCount * 3
        var values = [Float]()
        values.reserveCapacity(canonicalSlots.count * Self.channels)
        for slot in canonicalSlots {
            if let slot, slot.count == width {
                values += slot
                values.append(0)
            } else {
                values += [Float](repeating: 0, count: width)
                values.append(1)
            }
        }
        frameCount = canonicalSlots.count
        self.values = values
    }

    /// The input for one person's scored frames: laid on the analysis grid as contribution lays
    /// them (`ContributionPose`), then resampled to 10 Hz. `nil` without the two frames a grid
    /// needs. `duration` extends the grid to the end of the video when it is known.
    init?(frames: [PoseFrameResult], duration: TimeInterval?) {
        guard let pose = ContributionPose(frames: frames, duration: duration ?? 0) else { return nil }
        self.init(canonicalSlots: pose.canonicalSlots)
    }
}
