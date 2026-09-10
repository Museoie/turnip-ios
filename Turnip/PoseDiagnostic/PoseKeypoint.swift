import Foundation

struct PoseKeypoint: Identifiable, Sendable {
    let id = UUID()
    let name: String
    /// Normalized 0-1. MoveNet's output order is (y, x, score) — y before x.
    let y: Float
    let x: Float
    let confidence: Float

    static let confidenceThreshold: Float = 0.3

    /// COCO keypoint order used by MoveNet Thunder's [1, 1, 17, 3] output tensor.
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
            throw PoseDiagnosticError.inferenceFailed(
                "Expected \(names.count * 3) values in model output, got \(values.count)"
            )
        }
        return names.enumerated().map { index, name in
            let base = index * 3
            return PoseKeypoint(name: name, y: values[base], x: values[base + 1], confidence: values[base + 2])
        }
    }
}

struct PoseFrameResult: Identifiable, Sendable {
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
