import CryptoKit
import Foundation
import os

/// Polls for trick-detection model updates and stages them for the loader.
/// `ModelUpdateLifecycle` runs it on launch and on every foreground
/// transition. Pose detection is not its concern: MoveNet always loads from the
/// app bundle.
///
/// The flow per check (`MODEL_CONTRACT.md` §4): fetch the manifest from
/// `<baseURL>/api/models/current`; if its `version` differs from both the
/// active and the pending model, and this app is at least its
/// `min_client_version`, download the artifact from its `url`, check its
/// `byte_size` and `sha256`, and stage it as the pending model. Staging never
/// touches the active model: `TrickModelLoader` tries the pending one at its
/// next load, once per launch, and only a successful load retires the active
/// one (see `ModelUpdateStore`).
///
/// An actor for three reasons: the check is `async` throughout (network,
/// disk), `lastError` is written from the check's continuation, and the
/// single-flight guard needs its try-acquire to be atomic. Actor isolation
/// keeps all three data-race-free without manual locking.
///
/// The service never throws: every failure is recorded on `lastError` and the
/// staged models are left as they were. A failed update must be silent to
/// the user, never a crash or a half-staged model. Neither cancellation nor a
/// model this app is too old for is a failure: both leave `lastError` nil.
///
/// Inert by default: a `nil` baseURL (no endpoint configured) makes
/// `checkForUpdates` a no-op with zero network traffic, keeping the "nothing
/// leaves the device" promise until an endpoint is set.
actor ModelUpdateService<Client: ModelUpdateClient> {
    private static var logger: Logger {
        Logger(subsystem: "com.hoiekim.turnip", category: "ModelUpdates")
    }

    private let baseURL: URL?
    private let client: Client
    private let store: ModelUpdateStore
    /// The app's `CFBundleShortVersionString`, held against each manifest's
    /// `min_client_version`.
    private let clientVersion: String?

    /// The failure from the most recent check, or `nil` when the last check
    /// succeeded or was a no-op. Typed as `ModelUpdateError` (not `Error`)
    /// so it is `Sendable` across the actor boundary — non-typed failures are
    /// boxed at the catch site.
    private(set) var lastError: ModelUpdateError?

    /// Whether a check is currently in flight. Set before the first await and
    /// cleared in `defer`, so the try-acquire in `checkForUpdates` is atomic
    /// under actor isolation: the first caller wins and every overlapping
    /// caller is suppressed rather than queued.
    private var isChecking = false

    init(baseURL: URL?, client: Client, store: ModelUpdateStore, clientVersion: String?) {
        self.baseURL = baseURL
        self.client = client
        self.store = store
        self.clientVersion = clientVersion
    }

    func checkForUpdates() async {
        // didBecomeActive fires on every foreground transition and each
        // firing spawns its own detached task, so two firings in quick
        // succession (app-switcher bounce, notification shade) would each
        // fetch the manifest and download the model bytes. Try-acquire, not
        // queued: the in-flight check already covers what the duplicate
        // wanted.
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        lastError = nil
        guard let baseURL else { return }

        do {
            guard let json = try await client.fetchManifest(
                from: baseURL.appendingPathComponent("api/models/current"))
            else { return }
            let manifest = try ModelUpdateManifest(json: json)
            // The version names the store's files, so a version that can't
            // is refused before any bytes move.
            try ModelUpdateStore.validate(version: manifest.version)
            guard shouldDownload(manifest) else { return }

            let downloadedURL = try await client.downloadModel(from: manifest.url)
            // downloadModel hands us a temp file — delete it once the bytes
            // are in memory, so each check doesn't leave a model-sized file
            // behind in tmp/ waiting on the OS to purge it. Runs on every
            // exit from this block, including the verification throws.
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            let bytes = try Data(contentsOf: downloadedURL)
            if let byteSize = manifest.byteSize, bytes.count != byteSize {
                throw ModelUpdateError.sizeMismatch
            }
            guard sha256Hex(bytes) == manifest.sha256.lowercased() else {
                throw ModelUpdateError.checksumMismatch
            }
            try store.stage(artifact: bytes, manifest: manifest)
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

    /// Whether the manifest names a model this app should download: one it
    /// doesn't already have, active or pending, that is meant for this app's
    /// version. A check that downloads nothing stays a cheap manifest fetch.
    private func shouldDownload(_ manifest: ModelUpdateManifest) -> Bool {
        if manifest.version == store.activeModel()?.version {
            // The farm is back on the model in use, so a model staged since
            // is no longer current and must not load at the next launch.
            if let pending = store.pendingModel() {
                store.discard(pending.version)
            }
            return false
        }
        if manifest.version == store.pendingModel()?.version {
            return false
        }
        guard manifest.admits(clientVersion: clientVersion) else {
            // Contract §5: an app too old for the model skips it silently.
            let version = manifest.version.rawValue
            let minimum = manifest.minClientVersion ?? ""
            Self.logger.notice(
                "Skipped trick model \(version, privacy: .public): needs app \(minimum, privacy: .public)")
            return false
        }
        return true
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
