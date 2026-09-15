import Foundation

/// On-disk home for staged OTA models.
///
/// Layout inside `baseURL` (Application Support in production, a temp dir in
/// tests):
/// - `<fileName>` — the staged model bytes, written atomically.
/// - `active-model.json` — `{ "version": "...", "fileName": "..." }`, written
///   atomically *after* the bytes, so a crash between the two leaves the
///   metadata pointing at the previous (complete) model rather than at bytes
///   that never landed.
///
/// The version is persisted to disk, not cached in memory: the whole point of
/// the feature is next-launch promotion, so a fresh store over the same
/// directory must read back the version a previous launch staged. Otherwise
/// every cold launch would treat the shipped model as newer and re-download
/// the full weights — the exact cost the "cheap manifest fetch per launch"
/// requirement exists to prevent.
struct ModelUpdateStore: Sendable {
    /// Directory holding the staged model and its metadata. Not created until
    /// the first stage — a store that never stages anything leaves no trace.
    let baseURL: URL

    /// The sidecar file name, hoisted so `stage()` can reject it: staging a
    /// model *under* this name would let the metadata write overwrite the
    /// model bytes it just staged (or vice versa), corrupting the store.
    private static let metadataFileName = "active-model.json"

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// The staged version, or `nil` when nothing has been staged yet.
    func activeVersion() -> ModelVersion? {
        try? readRecord().map { ModelVersion($0.version) }
    }

    /// File URL of the staged model bytes, or `nil` when nothing is staged or
    /// the bytes are missing (metadata without bytes is treated as no model).
    func activeModelURL() -> URL? {
        guard let record = try? readRecord() else { return nil }
        let url = baseURL.appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Atomically replaces the staged model. Bytes land first, metadata
    /// second (see the layout note above).
    func stage(modelData: Data, version: ModelVersion, fileName: String) throws {
        // Reject hostile file names before touching the filesystem: the name
        // must be a single path component (no slashes, not empty, not "." or
        // "..") so a malicious manifest can't stage outside the store dir.
        // The store's own sidecar name is rejected too — staging a model as
        // "active-model.json" would collide with the metadata file written
        // right after the bytes.
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              fileName != ".",
              fileName != "..",
              fileName != Self.metadataFileName else {
            throw ModelUpdateError.invalidManifest
        }
        try FileManager.default.createDirectory(
            at: baseURL, withIntermediateDirectories: true)
        try modelData.write(
            to: baseURL.appendingPathComponent(fileName), options: .atomic)
        let payload = try JSONEncoder().encode(
            StoredModel(version: version.rawValue, fileName: fileName))
        try payload.write(to: metadataURL, options: .atomic)
    }

    /// Evicts the staged record — metadata and bytes — so the next update check re-stages
    /// from the manifest instead of reusing a file the loader has already proven bad. The
    /// service short-circuits re-downloads while a record with an older-or-equal version
    /// exists, so without eviction a wrong-variant publish would repeat the wasted staged
    /// load on every run until a newer manifest ships.
    ///
    /// Best-effort: a failure to delete is swallowed because eviction always runs on an
    /// already-failing load path, where a second error would only mask the first. Only ever
    /// called for content/shape failures (see `MoveNetThunderModel.load()`), never transient
    /// ones — dropping a good model on an OOM would be worse than the retry.
    func clearActive() {
        guard let record = try? readRecord() else { return }
        try? FileManager.default.removeItem(
            at: baseURL.appendingPathComponent(record.fileName))
        try? FileManager.default.removeItem(at: metadataURL)
    }

    private var metadataURL: URL {
        baseURL.appendingPathComponent(Self.metadataFileName)
    }

    private func readRecord() throws -> StoredModel? {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            StoredModel.self, from: Data(contentsOf: metadataURL))
    }
}

/// The persisted sidecar; `Codable` so the store stays a thin file wrapper
/// with no bespoke serialization format to drift.
private struct StoredModel: Codable {
    var version: String
    var fileName: String
}

extension ModelUpdateStore {
    /// The store the app actually wires: `<Application Support>/ModelUpdates`.
    /// The directory is not created until the first stage — a device that
    /// never receives an update leaves no trace on disk.
    ///
    /// Optional because `urls(for:in:)` can theoretically return nothing; the
    /// loader and the lifecycle hook both treat a missing directory the way
    /// they treat an empty store (nothing staged, nothing to do).
    static var production: ModelUpdateStore? {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first.map {
            ModelUpdateStore(
                baseURL: $0.appendingPathComponent(
                    "ModelUpdates", isDirectory: true))
        }
    }
}
