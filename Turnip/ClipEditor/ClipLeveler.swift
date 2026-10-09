import AVFoundation
import Foundation

/// What Auto rotate asks: the rotation that levels a clip window. The take's own roll track
/// (`RollTrack`, written by the in-app camera) answers when there is one — the phone's
/// gravity reading is the roll, whatever the picture shows. A video with no track, which is
/// every imported one, falls back to reading the horizon off the picture (`HorizonLeveler`),
/// which is a guess: it is right on a sky-over-ground scene and confidently wrong in a gym,
/// which is why the editor's Reset rotate exists.
enum ClipLeveler {
    /// The leveling rotation for `window`, in `CropAdjustment.rotationRadians`'s convention,
    /// or `nil` when nothing could be measured: a track with no sample in the window, or no
    /// track and no horizon. Throws only on cancellation or an unreadable file.
    static func levelingRotation(in asset: AVAsset, window: TrickWindow) async throws -> Double? {
        if let tilts = try await RollTrack.tilts(in: asset, window: window) {
            return HorizonLeveler.levelingRotation(forHorizonTilts: tilts)
        }
        return try await HorizonLeveler.levelingRotation(in: asset, window: window)
    }
}
