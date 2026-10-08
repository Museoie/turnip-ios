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
    /// Name of the sidecar file the store reserves for its own metadata. It
    /// is never a valid staged-model name: `stage` rejects it so the model
    /// bytes and the metadata record can never collide on one path. Compared
    /// case-insensitively, because the store also runs on case-insensitive
    /// filesystems (macOS test runners), where `ACTIVE-MODEL.JSON` would hit
    /// the same path.
    private static let metadataFileName = "active-model.json"

    /// The scalar allowlist for staged file names: ASCII only
    /// (`[A-Za-z0-9._-]`). `CharacterSet.alphanumerics` is Unicode-wide and
    /// would admit lookalikes (Cyrillic `м` is an alphanumeric), while the
    /// documented contract is ASCII, so the set is spelled out explicitly.
    private static let fileNameAllowedScalars = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    /// The single fileName predicate every enforcement point uses. Both the
    /// service's pre-download gate and `stage`'s write-time gate call this,
    /// so the two can never disagree on one name — a name rejected here is
    /// rejected before any download, and the write-time gate catches any
    /// caller that bypasses the service.
    ///
    /// Valid names are a non-empty ASCII allowlist, a single path component
    /// (no slashes, not `.` or `..`), and never the store's own metadata
    /// name — compared case-insensitively, because the store also runs on
    /// case-insensitive filesystems (macOS test runners), where
    /// `ACTIVE-MODEL.JSON` would hit the same path as `active-model.json`.
    static func validate(fileName: String) throws {
        let safe = !fileName.isEmpty
            && fileName != "."
            && fileName != ".."
            && fileName.unicodeScalars.allSatisfy(fileNameAllowedScalars.contains)
            && fileName.lowercased() != metadataFileName
        guard safe else {
            throw ModelUpdateError.invalidManifest
        }
    }

    /// Directory holding the staged model and its metadata. Not created until
    /// the first stage — a store that never stages anything leaves no trace.
    let baseURL: URL

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
        // One enforcement point (see validate(fileName:) above): rejects
        // hostile names, the reserved metadata name, and non-ASCII names
        // before touching the filesystem, so a malicious manifest can't
        // stage outside the store dir or collide with the sidecar record.
        try Self.validate(fileName: fileName)
        try FileManager.default.createDirectory(
            at: baseURL, withIntermediateDirectories: true)
        try modelData.write(
            to: baseURL.appendingPathComponent(fileName), options: .atomic)
        let payload = try JSONEncoder().encode(
            StoredModel(version: version.rawValue, fileName: fileName))
        try payload.write(to: metadataURL, options: .atomic)
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
