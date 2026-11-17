import AVFoundation
import CoreGraphics
import Foundation

/// Reads the colour of the top a person wears from the video, where their pose puts their torso:
/// what Clip List's shirt colour filter compares clips by (`docs/UIUX.md` § "Clip List").
///
/// Its reading is a nonisolated async function, so the decoding runs off the main thread when the
/// main actor awaits it. Every frame is read on the device, and nothing read is kept past the
/// screen.
struct TorsoColorReader: Sendable {
    /// The colour of the top in `samples` — each channel's median over every reading point of
    /// every frame that decodes (`LabColor.median(of:)`) — or `nil` when no frame decodes or no
    /// point lands inside one. Returns `nil` once cancelled.
    ///
    /// Frames are decoded upright (`appliesPreferredTrackTransform`), since the keypoints are
    /// normalized in display orientation, and at their exact time: a frame a moment off has the
    /// person somewhere else.
    func color(of samples: [TorsoSample], in asset: AVAsset) async -> LabColor? {
        guard !samples.isEmpty else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = Self.maximumSize
        var readings: [LabColor] = []
        for sample in samples {
            guard !Task.isCancelled else { return nil }
            guard let image = await Self.image(at: sample.timestamp, from: generator) else { continue }
            readings += Self.colors(in: image, at: sample.readingPoints)
        }
        guard !Task.isCancelled else { return nil }
        return LabColor.median(of: readings)
    }

    /// Bounds the decoded frame on both sides, whichever way the video is turned. Enough for a
    /// far athlete's torso to span a few dozen pixels; the readings are a grid of single pixels,
    /// so a larger frame would cost decoding and read no better.
    static let maximumSize = CGSize(width: 480, height: 480)

    /// The frame at `time`, exactly, or within `ClipThumbnailLoader.fallbackSeekTolerance` where
    /// the exact frame won't decode (some exact seeks fail with "Cannot Decode" where a frame a
    /// moment away decodes).
    private static func image(at time: TimeInterval, from generator: AVAssetImageGenerator) async -> CGImage? {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let image = try? await generator.image(at: cmTime).image { return image }
        guard !Task.isCancelled else { return nil }
        generator.requestedTimeToleranceBefore = ClipThumbnailLoader.fallbackSeekTolerance
        generator.requestedTimeToleranceAfter = ClipThumbnailLoader.fallbackSeekTolerance
        return try? await generator.image(at: cmTime).image
    }

    /// The colour of `image` at each of `points`, normalized to the image (y down from the top),
    /// in sRGB. Points outside the image are skipped.
    static func colors(in image: CGImage, at points: [CGPoint]) -> [LabColor] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return [] }
        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        // A bitmap context's first row in memory is the top of what was drawn into it.
        return points.compactMap { point in
            guard (0..<1).contains(point.x), (0..<1).contains(point.y) else { return nil }
            let offset = Int(point.y * CGFloat(height)) * rowBytes + Int(point.x * CGFloat(width)) * 4
            return LabColor(
                red: Float(pixels[offset]) / 255,
                green: Float(pixels[offset + 1]) / 255,
                blue: Float(pixels[offset + 2]) / 255)
        }
    }
}
