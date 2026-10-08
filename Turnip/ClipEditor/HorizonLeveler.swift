import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// The camera's roll over a clip window, read off the picture itself: the tilt of the
/// horizon Vision finds in frames sampled across the window, and the one rotation that
/// levels it (`docs/UIUX.md` § "Clip Detail / Editor", Auto rotate). The recordings carry
/// no motion data to take a roll from — nothing in the track's metadata, nothing from the
/// in-app camera — so the horizon in the image is the roll. The roll can drift during a
/// clip; the leveling rotation cancels the mean tilt over the window.
///
/// Angles here are in the editor's screen convention — `CropAdjustment.rotationRadians`'s
/// space, y down, a positive angle turning clockwise — so a tilt converts to a rotation
/// by negation and nothing else. Vision's horizon angle already carries that sign: a
/// horizon whose right end sits lower on screen reports positive (`HorizonLevelerTests`
/// pins this on synthetic frames, since the documentation doesn't say).
///
/// Every function is `nonisolated`, and an async one never runs on its caller's actor: the
/// frame decode and the Vision request stay off the main thread, and only angles come
/// back — the decoded `CGImage`s never cross an isolation boundary.
enum HorizonLeveler {
    /// How many frames are sampled across the window. The horizon moves slowly next to the
    /// athlete, so a handful of frames averages the drift; each one is a seek and a decode.
    static let sampleCount = 8
    /// Decoded-frame bound: the horizon is a whole-frame feature, so a small decode finds it
    /// as well as a native-resolution one, in a fraction of the time and memory.
    static let maximumSampleSize = CGSize(width: 640, height: 640)
    /// Seek tolerance per sample. A frame near the sample time is as good as the exact one
    /// for a horizon, and the tolerance lets the generator stop at a nearby keyframe
    /// instead of decoding the whole group of pictures up to the exact frame.
    static let seekTolerance = CMTime(seconds: 0.25, preferredTimescale: 600)

    /// The rotation that levels the window's horizon, or `nil` when no sampled frame shows
    /// one the detector finds (an indoor clip, a frame filled by the athlete). Throws only
    /// on cancellation; an undecodable sample is skipped.
    static func levelingRotation(in asset: AVAsset, window: TrickWindow) async throws -> Double? {
        levelingRotation(forHorizonTilts: try await horizonTilts(in: asset, window: window))
    }

    /// The per-frame horizon tilts across `window`, one per sampled frame the detector
    /// found a horizon in, in the screen convention. Frames are decoded in display
    /// orientation (`appliesPreferredTrackTransform`): the tilt has to be measured in the
    /// space the editor rotates in, and a portrait recording is stored on its side.
    static func horizonTilts(in asset: AVAsset, window: TrickWindow) async throws -> [Double] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSampleSize
        generator.requestedTimeToleranceBefore = seekTolerance
        generator.requestedTimeToleranceAfter = seekTolerance
        var tilts: [Double] = []
        for time in sampleTimes(in: window) {
            try Task.checkCancellation()
            let sampleTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let image = try? await generator.image(at: sampleTime).image else { continue }
            if let tilt = horizonTilt(in: image) {
                tilts.append(tilt)
            }
        }
        return tilts
    }

    /// `count` times spread evenly across `window`: the midpoints of `count` equal
    /// sub-ranges, so the samples sit inside the clip rather than on its edges, where the
    /// seek tolerance could reach a frame outside the window.
    static func sampleTimes(in window: TrickWindow, count: Int = sampleCount) -> [TimeInterval] {
        let length = window.endTime - window.startTime
        guard count > 0, length > 0 else { return [] }
        return (0..<count).map { index in
            window.startTime + length * (Double(index) + 0.5) / Double(count)
        }
    }

    /// The tilt of the horizon in `image`, in the screen convention, or `nil` when the
    /// detector finds none — which includes a picture whose horizon is already level, as
    /// well as one without a horizon.
    static func horizonTilt(in image: CGImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { return nil }
        return Double(observation.angle)
    }

    /// The rotation that cancels the mean of `tilts`: a horizon tilted clockwise on
    /// screen levels under a counterclockwise turn of the same size. A plain mean —
    /// a clip's roll stays within a few degrees of level, far from the ±90° wrap where
    /// a line's angle would need circular averaging. `nil` for no tilts.
    static func levelingRotation(forHorizonTilts tilts: [Double]) -> Double? {
        guard !tilts.isEmpty else { return nil }
        return -(tilts.reduce(0, +) / Double(tilts.count))
    }
}
