import AVFoundation
import CoreGraphics
import Foundation
import os

/// The pose of every video Turnip has scored, kept on the device until the app is deleted
/// (`docs/DESIGN.md` § "Pose archive"): what an analysis scored from the file, and what the camera
/// scored live while recording a take. Analyzing a video again — after backing out of its clip
/// list without saving, or days later — reads the frames already scored instead of running the
/// pose model over the file a second time.
///
/// One entry per video, by its `PHAsset.localIdentifier`: the frames in `PoseFrameStore`'s own file
/// format, and beside them what reusing them takes — the spacing they were scored at, the size
/// their keypoints are normalized against, the pose model that scored them, and the fingerprint of
/// the file they were scored from (`Fingerprint`), so an entry for a video edited in Photos since
/// is passed over. An entry holds whatever was scored, the whole video or part of it: Processing
/// scores only what it misses (`PoseBackfill`), and keeps the merged take in its place.
///
/// In `Application Support/`, which the system never purges, rather than `Caches/`, and out of
/// device backups: it can always be scored again from the video.
struct VideoPoseArchive: Sendable {
    /// `nil` when the app has no `Application Support/`, and nothing is kept.
    let directory: URL?

    static let shared = VideoPoseArchive(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("VideoPoses", isDirectory: true))

    /// What tells one version of a video's file from another: its exact length, and a coarse
    /// picture of three of its frames (`averageHash`). An edit saved in Photos changes one or the
    /// other — a trim the length; a crop, a rotation or a revert the pictures — and then its old
    /// entry reads as none and the video is scored afresh. So does an edit to colour alone, whose
    /// pose would have been the same: only scoring it again costs anything.
    struct Fingerprint: Codable, Equatable, Sendable {
        /// The file's length in seconds, the container's own figure.
        let duration: TimeInterval
        /// `averageHash` of the frames at a quarter, half and three quarters of the length.
        let frameHashes: [UInt64]

        /// The bits two hashes of one file may differ by: another iOS can scale a frame down a
        /// little differently. A different picture differs by far more.
        static let hashTolerance = 6

        /// Read off `asset`'s file; `nil` when it has no length or a frame won't decode, and then
        /// nothing is kept for it or reused.
        static func of(_ asset: AVAsset) async -> Fingerprint? {
            guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else {
                return nil
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 64, height: 64)
            // A little latitude, as the poster has (`ClipThumbnailLoader.fallbackSeekTolerance`): some
            // exact frames won't decode, and the frame picked within it is the same on every read.
            generator.requestedTimeToleranceBefore = ClipThumbnailLoader.fallbackSeekTolerance
            generator.requestedTimeToleranceAfter = ClipThumbnailLoader.fallbackSeekTolerance
            var hashes: [UInt64] = []
            for fraction in [0.25, 0.5, 0.75] {
                let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
                guard let frame = try? await generator.image(at: time).image,
                      let hash = averageHash(of: frame)
                else { return nil }
                hashes.append(hash)
            }
            return Fingerprint(duration: duration, frameHashes: hashes)
        }

        /// Whether `other` was read off the same file. The length is the same to the millisecond;
        /// the pictures, to `hashTolerance` bits.
        func matches(_ other: Fingerprint) -> Bool {
            abs(duration - other.duration) < 0.001
                && frameHashes.count == other.frameHashes.count
                && zip(frameHashes, other.frameHashes).allSatisfy { ($0 ^ $1).nonzeroBitCount <= Self.hashTolerance }
        }

        /// `image` drawn grey at 8 × 8, one bit per pixel brighter than their mean, the first row's
        /// leftmost pixel in the lowest bit.
        static func averageHash(of image: CGImage) -> UInt64? {
            let side = 8
            var pixels = [UInt8](repeating: 0, count: side * side)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return nil }
            let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
            var hash: UInt64 = 0
            for (index, value) in pixels.enumerated() where Int(value) > mean {
                hash |= 1 << UInt64(index)
            }
            return hash
        }
    }

    /// Written beside each entry's frames, last, so an entry whose frames are being replaced has
    /// none and reads as no entry.
    private struct Metadata: Codable {
        let version: Int
        let poseModel: String
        let interval: TimeInterval
        let renderedWidth: Double
        let renderedHeight: Double
        let fingerprint: Fingerprint
    }

    /// Bumped when what an entry means changes in a way `poseModel` and the frames' own format
    /// version (`PoseFrameStore`) don't already say, such as a new normalization of the keypoints.
    private static let version = 1

    /// The pose model, and the input size it ran at, that every entry kept now was scored by:
    /// one scored by another reads as none.
    private static let poseModel = "movenet-multipose-lightning-\(MoveNetMultiPoseModel.inputLongSide)"

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "VideoPoseArchive")

    /// Keeps `pose` as the video `assetIdentifier`'s, replacing what was kept for it before.
    /// `fingerprint` is the file the pose was scored from. A pose with no frames is not kept. Best
    /// effort: a failure is logged, and leaves the video with no entry.
    func keep(_ pose: PartialPoseFrames, for assetIdentifier: String, fingerprint: Fingerprint) {
        guard let directory, !pose.store.isEmpty else { return }
        let urls = entryURLs(for: assetIdentifier, in: directory)
        let fileManager = FileManager.default
        let incoming = urls.frames.appendingPathExtension("incoming")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.excludeFromBackup(directory)
            try? fileManager.removeItem(at: incoming)
            try pose.store.copyFile(to: incoming)
            // The old entry stops being one before its frames go, and the new one becomes one only
            // once its frames are in place: a crash between leaves the video with none.
            try? fileManager.removeItem(at: urls.metadata)
            try? fileManager.removeItem(at: urls.frames)
            try fileManager.moveItem(at: incoming, to: urls.frames)
            let metadata = Metadata(
                version: Self.version, poseModel: Self.poseModel, interval: pose.interval,
                renderedWidth: Double(pose.renderedPixelSize.width),
                renderedHeight: Double(pose.renderedPixelSize.height), fingerprint: fingerprint)
            try JSONEncoder().encode(metadata).write(to: urls.metadata, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: incoming)
            Self.logger.error("Keeping a pose failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The pose kept for `assetIdentifier`, as a partial Processing scores the rest of, in a store
    /// of its own: the entry stays whatever the run does with it. `nil` when nothing is kept for
    /// the video, the entry can't be read, was kept the old way or by another pose model, or was
    /// scored from a file `fingerprint` no longer matches.
    func pose(for assetIdentifier: String, fingerprint: Fingerprint) -> PartialPoseFrames? {
        guard let directory else { return nil }
        let urls = entryURLs(for: assetIdentifier, in: directory)
        guard let data = try? Data(contentsOf: urls.metadata),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.version == Self.version,
              metadata.poseModel == Self.poseModel,
              metadata.fingerprint.matches(fingerprint),
              let store = try? PoseFrameStore(copying: urls.frames),
              !store.isEmpty
        else { return nil }
        return PartialPoseFrames(
            store: store, interval: metadata.interval,
            renderedPixelSize: CGSize(width: metadata.renderedWidth, height: metadata.renderedHeight))
    }

    /// An entry's two files, named by a hash of the identifier, which carries slashes.
    private func entryURLs(for assetIdentifier: String, in directory: URL) -> (frames: URL, metadata: URL) {
        let name = VideoIdentity.sha256Hex(Data(assetIdentifier.utf8))
        return (
            directory.appendingPathComponent("\(name).tpos"),
            directory.appendingPathComponent("\(name).json"))
    }

    private static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
