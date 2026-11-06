import Foundation
import os

/// The pose the clip library keeps (`docs/PROFILE_DESIGN.md` §2.2): each one a gzipped TKP1 file in
/// a `poses/` directory beside the library file, so the library's own file, rewritten whole on
/// every change, stays small. Once the original is gone from Photos these files are the only copy,
/// so they live with the library in `Application Support/`, in device backups.
///
/// A file is named by the hash of the pose it holds. Two clips of one person share a file without
/// anything tracking that, and a second analysis of the same video can't overwrite the pose an
/// earlier clip was cut from, which a person's ID alone couldn't promise: it only means something
/// inside one analysis.
struct SourcePoseStore: Sendable {
    /// `nil` when the app has no `Application Support/`, and nothing is kept.
    let directory: URL?

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "ClipLibrary")

    init(directory: URL?) {
        self.directory = directory
    }

    init(besideLibraryFile fileURL: URL?) {
        directory = fileURL?.deletingLastPathComponent().appendingPathComponent("poses", isDirectory: true)
    }

    /// Writes `pose` unless it is already here, and returns the ID its clips name. `nil` when it
    /// couldn't be written.
    func store(_ pose: ContributionPose) -> String? {
        let id = VideoIdentity.sha256Hex(pose.tkp1)
        guard let directory, let url = fileURL(for: id), let blob = pose.gzippedTKP1 else { return nil }
        guard !FileManager.default.fileExists(atPath: url.path) else { return id }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try blob.write(to: url, options: .atomic)
            return id
        } catch {
            Self.logger.error("Pose write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The stored pose, or `nil` when it is missing or unreadable.
    func pose(_ id: String) -> ContributionPose? {
        guard let url = fileURL(for: id), let blob = try? Data(contentsOf: url) else { return nil }
        return ContributionPose(gzippedTKP1: blob)
    }

    func remove(_ id: String) {
        guard let url = fileURL(for: id), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error("Pose delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileURL(for id: String) -> URL? {
        directory?.appendingPathComponent("\(id).tkp1.gz")
    }
}
