import CryptoKit
import Foundation

/// Polls for model updates and stages them for the *next* launch.
///
/// The flow per check: fetch the manifest from
/// `<baseURL>/api/models/current`; if it names a newer version than the staged
/// one, download the bytes, verify their SHA-256 against the manifest, and
/// atomically stage them. The running session never hot-swaps models
/// mid-inference — staging only affects what the next launch loads.
///
/// An actor for two reasons: the check is `async` throughout (network, disk),
/// and `lastError` is written from the check's continuation, so actor
/// isolation keeps the read in tests data-race-free without manual locking.
///
/// The service never throws: every failure is recorded on `lastError` and the
/// previously staged model keeps serving. A failed update must be silent to
/// the user, never a crash or a half-staged model. Cancellation is not a
/// failure: a cancelled check leaves `lastError` nil instead of recording
/// the cancellation as a failed check.
///
/// Inert by default: a `nil` baseURL (no endpoint configured) makes
/// `checkForUpdates` a no-op with zero network traffic, keeping the "nothing
/// leaves the device" promise until a deployment exists.
actor ModelUpdateService<Client: ModelUpdateClient> {
    private let baseURL: URL?
    private let client: Client
    private let store: ModelUpdateStore

    /// The failure from the most recent check, or `nil` when the last check
    /// succeeded or was a no-op. Typed as `ModelUpdateError` (not `Error`)
    /// so it is `Sendable` across the actor boundary — non-typed failures are
    /// boxed at the catch site.
    private(set) var lastError: ModelUpdateError?

    init(baseURL: URL?, client: Client, store: ModelUpdateStore) {
        self.baseURL = baseURL
        self.client = client
        self.store = store
    }

    func checkForUpdates() async {
        lastError = nil
        guard let baseURL else { return }

        do {
            let manifest = try await client.fetchManifest(
                from: baseURL.appendingPathComponent("api/models/current"))
            try Self.validate(manifest)
            if let active = store.activeVersion(), manifest.version <= active {
                // Same or older: the check stays a cheap manifest fetch, not a
                // model fetch, on every launch.
                return
            }
            let downloadedURL = try await client.downloadModel(
                from: manifest.downloadURL)
            // downloadModel hands us a temp file — delete it once the bytes
            // are in memory, so each check doesn't leave a model-sized file
            // behind in tmp/ waiting on the OS to purge it. Runs on every
            // exit from this block, including the checksum-mismatch throw.
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            let bytes = try Data(contentsOf: downloadedURL)
            guard sha256Hex(bytes) == manifest.sha256.lowercased() else {
                throw ModelUpdateError.checksumMismatch
            }
            try store.stage(
                modelData: bytes, version: manifest.version,
                fileName: manifest.fileName)
        } catch is CancellationError {
            // Cancellation is a deliberate stop, not a failed check: the
            // cancelled task is already winding down, so don't record it on
            // lastError where it would be misreported as an update failure.
            // Re-throwing would be the alternative, but the service's
            // never-throws contract is intentional and tested
            // ("must not throw" in ModelUpdateTests), so a cancelled check
            // stays silent rather than throwing.
            lastError = nil
        } catch {
            // Narrow to the typed failure: typed errors pass through
            // untouched, anything else (disk reads, store writes, foreign
            // client implementations) is boxed as a description so the
            // stored value stays `Sendable`.
            lastError = error as? ModelUpdateError
                ?? .network(underlying: String(describing: error))
        }
    }

    /// Rejects a manifest whose `fileName` could escape the OTA directory.
    /// A positive allowlist (`[A-Za-z0-9._-]`, non-empty, not `.`/`..`) rather
    /// than a blacklist of known-bad spellings: the dangerous class here is
    /// *additions* (new traversal spellings), which a blacklist can never
    /// enumerate. Checked before any download, so hostile bytes never move.
    private static func validate(_ manifest: ModelUpdateManifest) throws {
        let fileName = manifest.fileName
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
        let isSafe = !fileName.isEmpty
            && fileName != "."
            && fileName != ".."
            && fileName.unicodeScalars.allSatisfy(allowed.contains)
        guard isSafe else {
            throw ModelUpdateError.invalidManifest
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
