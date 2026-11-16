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
/// their keypoints are normalized against, and the video's length when they were scored, so an
/// entry for a video trimmed in Photos since is passed over. An entry holds whatever was scored,
/// the whole video or part of it: Processing scores only what it misses (`PoseBackfill`), and
/// keeps the merged take in its place.
///
/// In `Application Support/`, which the system never purges, rather than `Caches/`, and out of
/// device backups: it can always be scored again from the video.
struct VideoPoseArchive: Sendable {
    /// `nil` when the app has no `Application Support/`, and nothing is kept.
    let directory: URL?

    static let shared = VideoPoseArchive(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("VideoPoses", isDirectory: true))

    /// How far the video's length may be from the one its entry was scored from. More than a
    /// container's rounding, less than any trim.
    static let durationTolerance: TimeInterval = 0.25

    /// Written beside each entry's frames, last, so an entry whose frames are being replaced has
    /// none and reads as no entry.
    private struct Metadata: Codable {
        let version: Int
        let interval: TimeInterval
        let renderedWidth: Double
        let renderedHeight: Double
        let duration: TimeInterval
    }

    /// Bumped when what an entry's frames mean changes — a new pose model, or a new normalization
    /// — so entries scored the old way read as none and are scored again.
    private static let version = 1

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "VideoPoseArchive")

    /// Keeps `pose` as the video `assetIdentifier`'s, replacing what was kept for it before.
    /// `duration` is the video's length in seconds. A pose with no frames is not kept. Best
    /// effort: a failure is logged, and leaves the video with no entry.
    func keep(_ pose: PartialPoseFrames, for assetIdentifier: String, duration: TimeInterval) {
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
                version: Self.version, interval: pose.interval,
                renderedWidth: Double(pose.renderedPixelSize.width),
                renderedHeight: Double(pose.renderedPixelSize.height), duration: duration)
            try JSONEncoder().encode(metadata).write(to: urls.metadata, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: incoming)
            Self.logger.error("Keeping a pose failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The pose kept for `assetIdentifier`, as a partial Processing scores the rest of, in a store
    /// of its own: the entry stays whatever the run does with it. `nil` when nothing is kept for
    /// the video, the entry can't be read or was kept the old way, or it was scored from a video
    /// `duration` seconds long no longer describes.
    func pose(for assetIdentifier: String, duration: TimeInterval) -> PartialPoseFrames? {
        guard let directory else { return nil }
        let urls = entryURLs(for: assetIdentifier, in: directory)
        guard let data = try? Data(contentsOf: urls.metadata),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.version == Self.version,
              abs(metadata.duration - duration) <= Self.durationTolerance,
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
