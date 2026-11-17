import CoreGraphics
import Foundation

/// A colour in CIE L\*a\*b\* (D65 white), where the distance between two colours follows how
/// different they look rather than how far apart their RGB values are.
struct LabColor: Hashable, Sendable {
    /// L\*: 0 is black, 100 white.
    let lightness: Float
    /// a\*: negative is green, positive red.
    let greenRed: Float
    /// b\*: negative is blue, positive yellow.
    let blueYellow: Float

    init(lightness: Float, greenRed: Float, blueYellow: Float) {
        self.lightness = lightness
        self.greenRed = greenRed
        self.blueYellow = blueYellow
    }

    /// The colour of sRGB components, each 0...1.
    init(red: Float, green: Float, blue: Float) {
        let linearRed = Self.linearized(red)
        let linearGreen = Self.linearized(green)
        let linearBlue = Self.linearized(blue)
        let scaledX = (0.4124564 * linearRed + 0.3575761 * linearGreen + 0.1804375 * linearBlue) / Self.whiteX
        let scaledY = 0.2126729 * linearRed + 0.7151522 * linearGreen + 0.0721750 * linearBlue
        let scaledZ = (0.0193339 * linearRed + 0.1191920 * linearGreen + 0.9503041 * linearBlue) / Self.whiteZ
        let curvedX = Self.curved(scaledX)
        let curvedY = Self.curved(scaledY)
        let curvedZ = Self.curved(scaledZ)
        self.init(
            lightness: 116 * curvedY - 16,
            greenRed: 500 * (curvedX - curvedY),
            blueYellow: 200 * (curvedY - curvedZ))
    }

    /// The colour of `color`, converted to sRGB first and clamped into it; `nil` when it can't be
    /// converted.
    init?(_ color: CGColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return nil }
        let clamped = components.prefix(3).map { Float(min(max($0, 0), 1)) }
        self.init(red: clamped[0], green: clamped[1], blue: clamped[2])
    }

    /// This colour in sRGB, clamped into it where it lies outside: what a swatch or a colour
    /// picker shows.
    var cgColor: CGColor {
        let curvedY = (lightness + 16) / 116
        let curvedX = curvedY + greenRed / 500
        let curvedZ = curvedY - blueYellow / 200
        let scaledX = Self.whiteX * Self.uncurved(curvedX)
        let scaledY = Self.uncurved(curvedY)
        let scaledZ = Self.whiteZ * Self.uncurved(curvedZ)
        let linearRed = 3.2404542 * scaledX - 1.5371385 * scaledY - 0.4985314 * scaledZ
        let linearGreen = -0.9692660 * scaledX + 1.8760108 * scaledY + 0.0415560 * scaledZ
        let linearBlue = 0.0556434 * scaledX - 0.2040259 * scaledY + 1.0572252 * scaledZ
        return CGColor(
            srgbRed: CGFloat(Self.encoded(linearRed)), green: CGFloat(Self.encoded(linearGreen)),
            blue: CGFloat(Self.encoded(linearBlue)), alpha: 1)
    }

    /// How different two colours look: the distance between them in L\*a\*b\*, with lightness
    /// counting `1 / lightnessWeight` as much as hue. One shirt in shade and in sun, or lit from
    /// two sides, differs mostly in lightness.
    func distance(to other: LabColor) -> Float {
        let lightnessGap = (lightness - other.lightness) / Self.lightnessWeight
        let greenRedGap = greenRed - other.greenRed
        let blueYellowGap = blueYellow - other.blueYellow
        return (lightnessGap * lightnessGap + greenRedGap * greenRedGap + blueYellowGap * blueYellowGap)
            .squareRoot()
    }

    /// How much less a difference in lightness counts in `distance(to:)` than one in hue.
    static let lightnessWeight: Float = 2

    /// Each channel's median over `colors`: a stripe, a logo or an arm across the chest is
    /// outvoted by the shirt around it. `nil` for no colours.
    static func median(of colors: [LabColor]) -> LabColor? {
        guard !colors.isEmpty else { return nil }
        return LabColor(
            lightness: Float(colors.map { Double($0.lightness) }.median),
            greenRed: Float(colors.map { Double($0.greenRed) }.median),
            blueYellow: Float(colors.map { Double($0.blueYellow) }.median))
    }

    // MARK: - sRGB ↔ XYZ ↔ L*a*b*

    /// The D65 white's X and Z, the sums of the sRGB-to-XYZ matrix's rows; its Y is 1.
    private static let whiteX: Float = 0.95047
    private static let whiteZ: Float = 1.08883
    /// (6/29)³, where L\*a\*b\*'s cube root gives way to a straight line near black.
    private static let linearLimit: Float = 216.0 / 24389.0
    /// The straight line's slope, (29/3)³.
    private static let linearSlope: Float = 24389.0 / 27.0

    private static func linearized(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ linear: Float) -> Float {
        let value = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return min(max(value, 0), 1)
    }

    private static func curved(_ ratio: Float) -> Float {
        ratio > linearLimit ? cbrt(ratio) : (linearSlope * ratio + 16) / 116
    }

    private static func uncurved(_ curved: Float) -> Float {
        let cubed = curved * curved * curved
        return cubed > linearLimit ? cubed : (116 * curved - 16) / linearSlope
    }
}

/// One frame of a person to read the colour of their top from: when it is, and where their
/// shoulders and hips are then, normalized like `PoseKeypoint` (display orientation, y down).
struct TorsoSample: Equatable, Sendable {
    let timestamp: TimeInterval
    let leftShoulder: CGPoint
    let rightShoulder: CGPoint
    let leftHip: CGPoint
    let rightHip: CGPoint
    /// The least confident of the four joints.
    let confidence: Float

    /// The torso in `frame`, or `nil` unless all four of its corners are located
    /// (`PoseKeypoint.confidenceThreshold`).
    init?(frame: PoseFrameResult) {
        func located(_ name: String) -> PoseKeypoint? {
            frame.keypoints.first { $0.name == name && $0.confidence > PoseKeypoint.confidenceThreshold }
        }
        guard let leftShoulder = located("left_shoulder"), let rightShoulder = located("right_shoulder"),
              let leftHip = located("left_hip"), let rightHip = located("right_hip")
        else { return nil }
        self.init(
            timestamp: frame.timestamp,
            leftShoulder: CGPoint(x: CGFloat(leftShoulder.x), y: CGFloat(leftShoulder.y)),
            rightShoulder: CGPoint(x: CGFloat(rightShoulder.x), y: CGFloat(rightShoulder.y)),
            leftHip: CGPoint(x: CGFloat(leftHip.x), y: CGFloat(leftHip.y)),
            rightHip: CGPoint(x: CGFloat(rightHip.x), y: CGFloat(rightHip.y)),
            confidence: [leftShoulder, rightShoulder, leftHip, rightHip].map(\.confidence).min() ?? 0)
    }

    init(
        timestamp: TimeInterval, leftShoulder: CGPoint, rightShoulder: CGPoint, leftHip: CGPoint,
        rightHip: CGPoint, confidence: Float
    ) {
        self.timestamp = timestamp
        self.leftShoulder = leftShoulder
        self.rightShoulder = rightShoulder
        self.leftHip = leftHip
        self.rightHip = rightHip
        self.confidence = confidence
    }

    /// Hips below shoulders: the person isn't upside down, mid-flip, where the joints run ahead of
    /// a blurred body and a reading lands off the clothes.
    var isUpright: Bool {
        leftHip.y + rightHip.y > leftShoulder.y + rightShoulder.y
    }

    /// Where the colour is read: a grid across the torso, kept in from its edges so it lands on
    /// the top rather than the arms beside it or the waistband below.
    var readingPoints: [CGPoint] {
        Self.downFractions.flatMap { down in
            Self.acrossFractions.map { across in
                let top = Self.point(from: leftShoulder, to: rightShoulder, at: across)
                let bottom = Self.point(from: leftHip, to: rightHip, at: across)
                return Self.point(from: top, to: bottom, at: down)
            }
        }
    }

    /// Shoulder to shoulder and hip to hip.
    private static let acrossFractions: [CGFloat] = [0.2, 0.35, 0.5, 0.65, 0.8]
    /// Shoulders to hips.
    private static let downFractions: [CGFloat] = [0.15, 0.3, 0.45, 0.6, 0.75]

    private static func point(from start: CGPoint, to end: CGPoint, at fraction: CGFloat) -> CGPoint {
        CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
    }

    /// The frames of `frames` inside `window` to read a person's top from: up to `count` whose
    /// whole torso is located, upright ones first and then the surest, each at least `spacing` from
    /// the others so one moment of an arm across the chest can't decide the colour. In time order.
    static func picks(
        from frames: [PoseFrameResult], in window: TrickWindow, count: Int = 2, spacing: TimeInterval = 0.5
    ) -> [TorsoSample] {
        let candidates = frames
            .filter { $0.timestamp >= window.startTime && $0.timestamp <= window.endTime }
            .compactMap(TorsoSample.init(frame:))
            .sorted { lhs, rhs in
                if lhs.isUpright != rhs.isUpright { return lhs.isUpright }
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.timestamp < rhs.timestamp
            }
        var picked: [TorsoSample] = []
        for candidate in candidates
        where picked.count < count && picked.allSatisfy({ abs($0.timestamp - candidate.timestamp) >= spacing }) {
            picked.append(candidate)
        }
        return picked.sorted { $0.timestamp < $1.timestamp }
    }
}
