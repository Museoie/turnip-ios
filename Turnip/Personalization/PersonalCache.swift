import Foundation
import os

/// What the personal layer has derived under one model version
/// (`docs/PERSONALIZATION_DESIGN.md` §7): each clip's embedding, and how far the rebuild has come.
/// Prototypes and the gate are left out because they read the clips' current names, which change
/// after a save, and take milliseconds to work out again.
struct PersonalCache: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = PersonalCache.currentSchemaVersion
    let modelVersion: String
    /// By clip ID.
    var clips: [String: ClipEmbedding] = [:]
    /// The stored poses the model has run over since this version activated, so an interrupted
    /// rebuild picks up where it stopped.
    var rebuiltPoseIDs: Set<String> = []
    /// Whether the library's poses have all been through this version. Until then the layer is off.
    var isRebuilt = false
}

/// The cache's one file in `Caches/`: out of backups, and iOS may evict it, since the rebuild can
/// make it again from the library. Unreadable reads as absent, for the same reason.
struct PersonalCacheStore: Sendable {
    let fileURL: URL?

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "Personalization")

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Personalization", isDirectory: true)
            .appendingPathComponent("personal-cache.json")
    }

    func load() -> PersonalCache? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let cache = try? JSONDecoder().decode(PersonalCache.self, from: data),
              cache.schemaVersion == PersonalCache.currentSchemaVersion
        else { return nil }
        return cache
    }

    func save(_ cache: PersonalCache) {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(cache)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Personal cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            Self.logger.error("Personal cache delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
