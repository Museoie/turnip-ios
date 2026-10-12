import Foundation
@testable import Turnip

/// A positioned keypoint seed for fixture builders: where the keypoint sits plus the
/// confidence the fixture should carry. The seed is shared by the crop-rect and
/// motion-signal fixtures in this target.
struct KeypointSeed {
    var x: Float
    var y: Float
    var confidence: Float
}

/// Synthetic `PoseFrameResult`s for the pose-consuming tests. No video and no model: `body`
/// lays out a whole confident athlete, which the motion signal needs; `frame` places only the
/// hips and upper body and fills the rest of the 17 keypoints in below the confidence threshold,
/// which is enough for crop and clip tests.
enum PoseFixture {
    /// 30 fps sampled at the pipeline's stride of 3.
    static let frameInterval: TimeInterval = 0.1

    private static let hipNames: Set<String> = ["left_hip", "right_hip"]
    private static let upperBodyNames: Set<String> = ["left_shoulder", "right_shoulder", "nose"]

    static func frame(
        index: Int,
        hip: (x: Float, y: Float)?,
        upperBody: (x: Float, y: Float)? = nil,
        leftHip: KeypointSeed? = nil,
        rightHip: KeypointSeed? = nil
    ) -> PoseFrameResult {
        let keypoints = PoseKeypoint.names.map { name -> PoseKeypoint in
            if name == "left_hip", let leftHip {
                return PoseKeypoint(name: name, y: leftHip.y, x: leftHip.x, confidence: leftHip.confidence)
            }
            if name == "right_hip", let rightHip {
                return PoseKeypoint(name: name, y: rightHip.y, x: rightHip.x, confidence: rightHip.confidence)
            }
            if let hip, hipNames.contains(name) {
                return PoseKeypoint(name: name, y: hip.y, x: hip.x, confidence: 0.9)
            }
            if let upperBody, upperBodyNames.contains(name) {
                return PoseKeypoint(name: name, y: upperBody.y, x: upperBody.x, confidence: 0.9)
            }
            return PoseKeypoint(name: name, y: 0, x: 0, confidence: 0.05)
        }
        return PoseFrameResult(
            frameIndex: index * 3,
            timestamp: Double(index) * frameInterval,
            keypoints: keypoints
        )
    }

    /// One frame per x position, hips confident, y fixed — the shape most motion fixtures want.
    /// `blankFrames` drops every keypoint on those indices below the confidence threshold.
    static func frames(hipXPositions: [Float], blankFrames: Set<Int> = []) -> [PoseFrameResult] {
        hipXPositions.enumerated().map { index, x in
            frame(index: index, hip: blankFrames.contains(index) ? nil : (x: x, y: 0.5))
        }
    }

    /// Where each joint of a standing athlete sits relative to the hip midpoint, in torso
    /// lengths (shoulder midpoint to hip midpoint), y down.
    static let standingLayout: [String: (x: Float, y: Float)] = [
        "nose": (0, -1.4), "left_eye": (-0.1, -1.5), "right_eye": (0.1, -1.5),
        "left_ear": (-0.2, -1.45), "right_ear": (0.2, -1.45),
        "left_shoulder": (-0.4, -1), "right_shoulder": (0.4, -1),
        "left_elbow": (-0.5, -0.5), "right_elbow": (0.5, -0.5),
        "left_wrist": (-0.5, 0), "right_wrist": (0.5, 0),
        "left_hip": (-0.25, 0), "right_hip": (0.25, 0),
        "left_knee": (-0.25, 0.9), "right_knee": (0.25, 0.9),
        "left_ankle": (-0.25, 1.8), "right_ankle": (0.25, 1.8)
    ]

    /// A whole athlete with every joint confident, laid out around the hip midpoint `hip` with
    /// a torso `torso` long in normalized units. The motion signal compares joint by joint and
    /// scales by torso length, so a fixture that wants motion measured needs a whole body.
    /// `offsets` moves single joints off the standing layout, in normalized units (a kick moves
    /// a leg, not the hips); `dropped` puts joints below the confidence threshold.
    static func body(
        index: Int,
        hip: (x: Float, y: Float),
        torso: Float = 0.1,
        offsets: [String: (x: Float, y: Float)] = [:],
        dropped: Set<String> = [],
        interval: TimeInterval = frameInterval
    ) -> PoseFrameResult {
        let keypoints = PoseKeypoint.names.map { name -> PoseKeypoint in
            let layout = standingLayout[name] ?? (0, 0)
            let offset = offsets[name] ?? (0, 0)
            return PoseKeypoint(
                name: name,
                y: hip.y + layout.y * torso + offset.y,
                x: hip.x + layout.x * torso + offset.x,
                confidence: dropped.contains(name) ? 0.05 : 0.9
            )
        }
        return PoseFrameResult(frameIndex: index * 3, timestamp: Double(index) * interval, keypoints: keypoints)
    }

    /// One whole-body frame per hip x position, y fixed — the body counterpart of `frames`.
    static func bodies(
        hipXPositions: [Float],
        torso: Float = 0.1,
        interval: TimeInterval = frameInterval
    ) -> [PoseFrameResult] {
        hipXPositions.enumerated().map { index, x in
            body(index: index, hip: (x: x, y: 0.5), torso: torso, interval: interval)
        }
    }

    /// Positions for a quiet head, a constant-speed slide, then a quiet tail.
    static func slide(
        quietFrames: Int,
        from start: Float,
        perFrame: Float,
        movingFrames: Int,
        tailFrames: Int
    ) -> [Float] {
        let moving = (1...movingFrames).map { start + perFrame * Float($0) }
        return [Float](repeating: start, count: quietFrames)
            + moving
            + [Float](repeating: moving[moving.count - 1], count: tailFrames)
    }
}
