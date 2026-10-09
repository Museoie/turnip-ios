import AVFoundation
import CoreMedia
import Foundation

/// The camera's roll, carried inside a take as a timed metadata track: written by the in-app
/// camera while it records (`RollTrackRecorder`), read back by the editor's Auto rotate
/// (`ClipLeveler`). The recordings' pictures give no reliable roll — Vision's horizon detector
/// locks onto a gym's trusses and floor lines with full confidence — but the phone's own
/// gravity reading does, and a track in the file survives the save to Photos, iCloud and
/// sharing where an app-private sidecar would not.
///
/// Each sample is the horizon's tilt in the displayed frame, in `HorizonLeveler`'s screen
/// convention (y down, positive clockwise, so a horizon whose right end sits lower reads
/// positive): the one quantity the leveler already negates into a rotation, so a take with a
/// track and a take without one go through the same `levelingRotation(forHorizonTilts:)`.
enum RollTrack {
    /// The metadata item identifier, in the `mdta` key space: the one string the capture
    /// input, the test fixture writer and the reader all have to agree on.
    static let identifier = "mdta/com.hoiekim.turnip.roll"
    static let dataType = kCMMetadataBaseDataType_Float64 as String
    /// How often the recorder samples gravity. The roll of a handheld phone changes slowly
    /// next to the athlete, and the editor averages a window's samples anyway.
    static let sampleInterval: TimeInterval = 1 / 30
    /// Each group's duration as appended: shorter than the interval so the next group's
    /// start never has to be pushed past its real time to keep the groups non-overlapping
    /// when motion updates arrive late or bunched. In the file a sample stays in force
    /// until the next one starts regardless, so a reader over a window also gets the
    /// sample that was in force as the window opened.
    static let sampleDuration = CMTime(value: 1, timescale: 60)

    /// The boxed-metadata format description for a roll track. Built once per writer: an
    /// `AVCaptureMetadataInput` and an `AVAssetWriterInput` both take it, and both refuse
    /// items whose identifier differs from it.
    static func makeFormatDescription() throws -> CMFormatDescription {
        var description: CMFormatDescription?
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: dataType
        ]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw RollTrackError.formatDescriptionFailed(status)
        }
        return description
    }

    /// One sample, ready to append to a capture input or a writer adaptor.
    static func timedGroup(tilt: Double, start: CMTime, duration: CMTime = sampleDuration) -> AVTimedMetadataGroup {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: identifier)
        item.dataType = dataType
        item.value = NSNumber(value: tilt)
        return AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: start, duration: duration))
    }

    // MARK: - Gravity to tilt

    /// The horizon's tilt in the recorded picture, from the gravity vector in the device
    /// frame (`CMDeviceMotion.gravity`: x to the right of the portrait screen, y toward the
    /// top of the phone, z out of the screen), the movie connection's clockwise rotation in
    /// `videoRotationAngle` terms, and which camera is recording.
    ///
    /// The picture's own up and right directions are expressed in the device frame, then the
    /// roll is the angle gravity makes with the picture's down: a phone the holder rolls
    /// clockwise (the top swinging right) shows the world turned counterclockwise through the
    /// back camera, so the horizon's right end rises and the tilt is negative — the sign the
    /// Vision path's own fixture pins. The front camera looks the other way, so the same
    /// roll tilts its picture the other way, and its picture-right is the device's left.
    ///
    /// Portrait (90°) and upside-down (270°) follow from the camera facing alone. The two
    /// landscape rotations assume the usual mountings — the back sensor's native picture is
    /// upright with the phone's top to the left, the front sensor's with it to the right —
    /// which nothing here can check; the camera never sets a landscape rotation today.
    ///
    /// `nil` when gravity has almost no component in the picture plane (the camera pointing
    /// nearly straight down or up), where a roll is not defined.
    static func tilt(
        gravityX: Double, gravityY: Double, gravityZ: Double,
        videoRotationDegrees: Int, isFrontCamera: Bool
    ) -> Double? {
        let radians = Double(videoRotationDegrees) * .pi / 180
        let (upX, upY) = isFrontCamera ? (-cos(radians), sin(radians)) : (cos(radians), sin(radians))
        // Picture-right is picture-up turned a quarter turn: clockwise as the holder sees the
        // phone for the back camera, counterclockwise for the front one, which faces the holder.
        let (rightX, rightY) = isFrontCamera ? (-upY, upX) : (upY, -upX)
        let alongRight = gravityX * rightX + gravityY * rightY
        let alongUp = gravityX * upX + gravityY * upY
        guard alongRight.isFinite, alongUp.isFinite,
              hypot(alongRight, alongUp) >= minimumInPlaneGravity
        else { return nil }
        return -atan2(alongRight, -alongUp)
    }

    /// The least of gravity (in g) that has to lie in the picture plane for the roll to mean
    /// anything: below it the camera points nearly along gravity.
    static let minimumInPlaneGravity = 0.2

    // MARK: - Reading

    /// The tilt samples inside `window`, or `nil` when `asset` carries no roll track at all —
    /// an imported video, or a slow-motion edit whose export dropped the track — so a caller
    /// can tell "nothing recorded" from "recorded, but no sample in this window". Throws on
    /// a reader failure; a sample that isn't a finite number is skipped.
    static func tilts(in asset: AVAsset, window: TrickWindow) async throws -> [Double]? {
        guard let track = try await rollTrack(in: asset) else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        guard reader.canAdd(output) else { throw RollTrackError.unreadable }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: window.startTime, preferredTimescale: 600),
            end: CMTime(seconds: window.endTime, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? RollTrackError.unreadable }
        defer { reader.cancelReading() }
        var tilts: [Double] = []
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items where item.identifier?.rawValue == identifier {
                if let value = item.numberValue?.doubleValue, value.isFinite {
                    tilts.append(value)
                }
            }
        }
        return tilts
    }

    /// The asset's roll track: the first metadata track whose format carries `identifier`.
    private static func rollTrack(in asset: AVAsset) async throws -> AVAssetTrack? {
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let descriptions = try await track.load(.formatDescriptions)
            let carriesRoll = descriptions.contains { description in
                let identifiers = CMMetadataFormatDescriptionGetIdentifiers(description) as? [String]
                return identifiers?.contains(identifier) ?? false
            }
            if carriesRoll { return track }
        }
        return nil
    }
}

enum RollTrackError: Error {
    case formatDescriptionFailed(OSStatus)
    case unreadable
}
