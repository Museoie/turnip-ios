import Foundation

struct PoseKeypoint: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    /// Nominally normalized 0-1 relative to the source frame — but honest about pad-region
    /// keypoints: a joint landing in the letterbox pad maps outside [0, 1] rather than being
    /// clamped to the edge, so downstream code must tolerate out-of-range values.
    /// MoveNet's output order is (y, x, score) — y before x.
    let y: Float
    let x: Float
    let confidence: Float

    static let confidenceThreshold: Float = 0.3

    /// COCO keypoint order, the order MoveNet emits each person's keypoints in.
    static let names = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
        "left_wrist", "right_wrist", "left_hip", "right_hip",
        "left_knee", "right_knee", "left_ankle", "right_ankle"
    ]

    /// Parses a flattened [y, x, score] x 17 tensor into keypoints.
    /// MoveNet emits y before x per keypoint — a well-known source of integration bugs if swapped.
    static func parse(from values: [Float]) throws -> [PoseKeypoint] {
        guard values.count == names.count * 3 else {
            throw PoseError.inferenceFailed(
                "Expected \(names.count * 3) values in model output, got \(values.count)"
            )
        }
        return names.enumerated().map { index, name in
            let base = index * 3
            return PoseKeypoint(name: name, y: values[base], x: values[base + 1], confidence: values[base + 2])
        }
    }
}

/// One person the pose model found in a frame: how sure it is that someone is there, the box
/// around them, and their 17 keypoints. Frame-normalized like `PoseKeypoint` once
/// `LetterboxMapping.frameNormalized(person:)` has mapped it.
struct DetectedPerson: Hashable, Sendable {
    let score: Float
    let box: NormalizedRect
    let keypoints: [PoseKeypoint]

    /// Below this the model is guessing that anyone is there at all. The reference
    /// implementation's own default for MultiPose.
    static let minimumScore: Float = 0.25

    /// The most people MultiPose's output holds per frame.
    static let maximumCount = 6

    /// Per person: 17 × (y, x, score), then the box as (ymin, xmin, ymax, xmax), then the score.
    static let valuesPerPerson = PoseKeypoint.names.count * 3 + 5

    /// Parses MultiPose's flattened `[1, 6, 56]` output into the people scoring at least
    /// `minimumScore`, in the model's order and still in its normalized input space. The box is
    /// y-first like the keypoints.
    static func parse(from values: [Float]) throws -> [DetectedPerson] {
        guard values.count == maximumCount * valuesPerPerson else {
            throw PoseError.inferenceFailed(
                "Expected \(maximumCount * valuesPerPerson) values in model output, got \(values.count)"
            )
        }
        let keypointValues = PoseKeypoint.names.count * 3
        return try (0..<maximumCount).compactMap { index in
            let person = Array(values[(index * valuesPerPerson)..<((index + 1) * valuesPerPerson)])
            let score = person[keypointValues + 4]
            guard score >= minimumScore else { return nil }
            return DetectedPerson(
                score: score,
                box: NormalizedRect(
                    minX: person[keypointValues + 1], maxX: person[keypointValues + 3],
                    minY: person[keypointValues], maxY: person[keypointValues + 2]),
                keypoints: try PoseKeypoint.parse(from: Array(person.prefix(keypointValues))))
        }
    }
}

extension Array where Element == DetectedPerson {
    /// The keypoints of the person the model is surest of, or none when it found nobody: the one
    /// pose a consumer that follows a single person reads per frame.
    var mostConfidentKeypoints: [PoseKeypoint] {
        self.max { $0.score < $1.score }?.keypoints ?? []
    }
}

/// Everyone the pose model found in one sampled frame, plus the frame as a consumer that follows
/// a single person reads it.
struct MultiPoseFrame: Hashable, Sendable {
    /// The pose of the person the model is surest of, or no pose when it found nobody. Built once
    /// rather than on each read, so it keeps one identity however often a consumer asks for it.
    let primary: PoseFrameResult
    let people: [DetectedPerson]

    var frameIndex: Int { primary.frameIndex }
    var timestamp: TimeInterval { primary.timestamp }

    init(frameIndex: Int, timestamp: TimeInterval, people: [DetectedPerson]) {
        self.init(
            primary: PoseFrameResult(
                frameIndex: frameIndex, timestamp: timestamp, keypoints: people.mostConfidentKeypoints),
            people: people)
    }

    init(primary: PoseFrameResult, people: [DetectedPerson]) {
        self.primary = primary
        self.people = people
    }
}

/// One person followed across a take: their pose at every sample from the first they were found
/// in to the last, with an empty pose wherever the model lost them in between. A missed sample
/// stays an unknown sample to the motion signal, which divides by the time between consecutive
/// frames, rather than becoming one longer step.
struct PoseTrack: Hashable, Sendable, Identifiable {
    let id: Int
    let frames: [PoseFrameResult]
}

/// `Hashable` (by every field, the fresh `id` included) so a video's frames can ride in
/// `DetectedClips` on a `SelectedVideo`, which the navigation path hashes.
struct PoseFrameResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let frameIndex: Int
    let timestamp: TimeInterval
    let keypoints: [PoseKeypoint]

    var averageConfidence: Double {
        guard !keypoints.isEmpty else { return 0 }
        let total = keypoints.reduce(0) { $0 + Double($1.confidence) }
        return total / Double(keypoints.count)
    }

    var usableKeypointCount: Int {
        keypoints.filter { $0.confidence > PoseKeypoint.confidenceThreshold }.count
    }
}
