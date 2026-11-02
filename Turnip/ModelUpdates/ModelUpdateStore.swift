import Foundation

/// On-disk home for the OTA trick-detection model. The app's update check
/// stages models here (see `ModelUpdateLifecycle`); `TrickModelLoader` loads
/// one once per launch and reports whether it loaded. Pose detection never
/// comes through here: MoveNet is always the bundled file.
///
/// Two slots, so a new model never costs the one that works
/// (`MODEL_CONTRACT.md` §4):
/// - **active**: the model that last loaded.
/// - **pending**: a model staged since, not yet loaded. The loader tries it
///   first. If it loads, it becomes active and the old active model is
///   deleted (`markLoaded`). If it doesn't, it is deleted and the active
///   model loads instead (`discard`).
///
/// Layout inside `baseURL` (`production`'s Application Support directory in
/// the app, a temp dir in tests):
/// - `<version>.mlpackage.zip`: a model's artifact, the bytes the farm served.
/// - `<version>.manifest.json`: the manifest it arrived with, as served.
/// - `staged-models.json`: `{ "active": "<version>", "pending": "<version>" }`,
///   either absent when its slot is empty, written atomically *after* the
///   files it names, so a crash between the two leaves it naming complete
///   files.
///
/// After each write of `staged-models.json`, everything else in the directory
/// that isn't one of its two models' files is deleted: a replaced pending
/// model, the active model a newer one succeeded, and any file the record
/// doesn't name, such as a crash's leftovers. The versions are persisted, not
/// cached, because a staged model waits for the next launch, and the next
/// launch's store has to read them back.
///
/// Every write takes one process-wide lock: the update check and the loader
/// each write through their own store over the same directory, and an
/// interleaved stage and promotion could otherwise lose a slot and sweep away
/// a model still in use.
struct ModelUpdateStore: Sendable {
    /// A model in the store.
    struct StagedModel: Equatable, Sendable {
        let version: ModelVersion
        /// The artifact as downloaded: the export's zip holding
        /// `TrickDetector.mlpackage`.
        let artifactURL: URL
        /// The manifest the artifact arrived with, exactly as the farm served
        /// it, kept for its `vocabulary`, `output_desc` and `name_metrics`.
        let manifestURL: URL

        fileprivate init(version: ModelVersion, in directory: URL) {
            self.version = version
            artifactURL = directory.appendingPathComponent("\(version.rawValue).mlpackage.zip")
            manifestURL = directory.appendingPathComponent("\(version.rawValue).manifest.json")
        }
    }

    private static let recordFileName = "staged-models.json"

    private static let lock = NSLock()

    /// The scalars a version may hold, since it names the store's files:
    /// ASCII only (`[A-Za-z0-9._-]`). `CharacterSet.alphanumerics` is
    /// Unicode-wide and would admit lookalikes (Cyrillic `м` is an
    /// alphanumeric), so the set is spelled out.
    private static let versionAllowedScalars = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    /// Throws `invalidManifest` for a version that can't name a file here: an
    /// empty one, one with a scalar outside the allowlist (a slash, a
    /// lookalike), or one with a leading dot, which would hide the file. The
    /// service checks it before any download, and `stage` before any write.
    static func validate(version: ModelVersion) throws {
        let raw = version.rawValue
        guard !raw.isEmpty, !raw.hasPrefix("."),
              raw.unicodeScalars.allSatisfy(versionAllowedScalars.contains)
        else {
            throw ModelUpdateError.invalidManifest
        }
    }

    /// Directory holding the models and their record. Not created until the
    /// first stage — a store that never stages anything leaves no trace.
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// The model that last loaded, or `nil` when none has, or its artifact is
    /// missing.
    func activeModel() -> StagedModel? {
        model(readableRecord()?.active)
    }

    /// The model staged since the active one, waiting to be loaded, or `nil`
    /// when there is none, or its artifact is missing.
    func pendingModel() -> StagedModel? {
        model(readableRecord()?.pending)
    }

    /// Stages a verified artifact as the pending model, replacing any pending
    /// model before it. The active model stays until the new one loads.
    ///
    /// Staging the active model's own version restores its files and leaves
    /// nothing pending. The update check never does: it skips a manifest that
    /// names the active model.
    func stage(artifact: Data, manifest: ModelUpdateManifest) throws {
        try Self.validate(version: manifest.version)
        try Self.lock.withLock {
            try FileManager.default.createDirectory(
                at: baseURL, withIntermediateDirectories: true)
            let staged = StagedModel(version: manifest.version, in: baseURL)
            try artifact.write(to: staged.artifactURL, options: .atomic)
            try manifest.json.write(to: staged.manifestURL, options: .atomic)
            // An unreadable record (corrupt, or of another schema) must not
            // wedge the store, since a throwing read here could never heal:
            // it counts as nothing staged, and the sweep clears what it named.
            var record = readableRecord() ?? Record()
            record.pending = record.active == manifest.version ? nil : manifest.version
            try write(record)
        }
    }

    /// Makes the pending model `version` the active one, once it has loaded,
    /// and deletes the model it succeeds. A no-op when `version` is no longer
    /// pending: an update staged a newer model while it loaded, and that one
    /// waits for the next launch, with the active model still kept.
    ///
    /// Best-effort, like `discard`: a failed write leaves the slots as they
    /// were, and the next launch loads the same pending model and tries again.
    func markLoaded(_ version: ModelVersion) {
        Self.lock.withLock {
            guard var record = readableRecord(), record.pending == version else { return }
            record.active = version
            record.pending = nil
            try? write(record)
        }
    }

    /// Deletes the pending model `version`, which didn't load, so the active
    /// model stays the one in use. A no-op when `version` is no longer
    /// pending.
    func discard(_ version: ModelVersion) {
        Self.lock.withLock {
            guard var record = readableRecord(), record.pending == version else { return }
            record.pending = nil
            try? write(record)
        }
    }

    private var recordURL: URL {
        baseURL.appendingPathComponent(Self.recordFileName)
    }

    private func model(_ version: ModelVersion?) -> StagedModel? {
        guard let version else { return nil }
        let staged = StagedModel(version: version, in: baseURL)
        return FileManager.default.fileExists(atPath: staged.artifactURL.path) ? staged : nil
    }

    private func readableRecord() -> Record? {
        try? JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
    }

    /// Writes the record, then sweeps the directory down to it. The sweep is
    /// best-effort: the slots are already right, and a file it misses goes on
    /// the next write.
    private func write(_ record: Record) throws {
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        let kept = Set([record.active, record.pending].compactMap { $0 }.flatMap { version in
            let staged = StagedModel(version: version, in: baseURL)
            return [staged.artifactURL.lastPathComponent, staged.manifestURL.lastPathComponent]
        } + [Self.recordFileName])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: baseURL.path)) ?? []
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: baseURL.appendingPathComponent(name))
        }
    }
}

/// The persisted slots; `Codable` so the store stays a thin file wrapper with
/// no bespoke serialization format to drift.
private struct Record: Codable {
    var active: ModelVersion?
    var pending: ModelVersion?
}

extension ModelUpdateStore {
    /// The store the app wires: `<Application Support>/ModelUpdates`. The
    /// directory is not created until the first stage — a device that never
    /// receives an update leaves no trace on disk.
    ///
    /// Optional because `urls(for:in:)` can in principle return nothing; the
    /// lifecycle hook treats a missing directory as nothing to do.
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
