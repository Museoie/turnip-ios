import CoreGraphics
@testable import Turnip

extension FollowCrop {
    /// A crop whose keyframes and resting framing all hold one zoom and one turn. A keyframe
    /// given an `autoCenter` is Auto follow's in all three, so it starts hollow.
    static func uniform(
        scale: CGFloat = 1, rotationRadians: Double = 0, keyframes: [FollowKeyframe], restingCenter: CGPoint,
        isAutoFollow: Bool
    ) -> FollowCrop {
        FollowCrop(
            keyframes: keyframes.map { keyframe in
                var keyframe = keyframe
                keyframe.scale = scale
                keyframe.rotationRadians = rotationRadians
                if keyframe.autoCenter != nil {
                    keyframe.autoScale = scale
                    keyframe.autoRotationRadians = rotationRadians
                }
                return keyframe
            },
            resting: FollowFraming(center: restingCenter, scale: scale, rotationRadians: rotationRadians),
            isAutoFollow: isAutoFollow)
    }
}
