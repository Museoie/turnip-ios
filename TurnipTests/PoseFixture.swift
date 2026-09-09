import Foundation
@testable import Turnip

/// Synthetic `PoseFrameResult`s for the motion-signal and peak-detection tests. No video and no
/// model: every fixture states the anchor position it wants and this fills the rest of the 17
/// keypoints in below the confidence threshold.
enum PoseFixture {
    /// 30 fps sampled at the pipeline's stride of 3.
    static let frameInterval: TimeInterval = 0.1

    static func frame(
        index: Int,
        hip: (x: Float, y: Float)?,
        upperBody: (x: Float, y: Float)? = nil,
        leftHip: (x: Float, y: Float, confidence: Float)? = nil,
        rightHip: (x: Float, y: Float, confidence: Float)? = nil
    ) -> PoseFrameResult {
        let keypoints = PoseKeypoint.names.map { name -> PoseKeypoint in
            if name == "left_hip", let leftHip {
                return PoseKeypoint(name: name, y: leftHip.y, x: leftHip.x, confidence: leftHip.confidence)
            }
            if name == "right_hip", let rightHip {
                return PoseKeypoint(name: name, y: rightHip.y, x: rightHip.x, confidence: rightHip.confidence)
            }
            if let hip, MotionSignalBuilder.hipKeypointNames.contains(name) {
                return PoseKeypoint(name: name, y: hip.y, x: hip.x, confidence: 0.9)
            }
            if let upperBody, MotionSignalBuilder.upperBodyKeypointNames.contains(name) {
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
