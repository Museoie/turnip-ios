import Foundation

/// Wires the OTA model-update service into the app lifecycle (issue #96).
///
/// The whole flow is inert until `TURNIP_MODEL_UPDATE_ENDPOINT` is configured:
/// with no endpoint `ModelUpdateConfiguration.endpoint` is nil and
/// `checkForUpdates` becomes a no-op with zero network traffic, so the v1
/// "nothing leaves the device" promise holds until a turnip-farm deployment
/// exists.
enum ModelUpdateLifecycle {
    /// One service for the process lifetime. `ModelUpdateService` suppresses
    /// overlapping checks with an in-flight guard, which only works when every
    /// foreground firing goes through the same instance — a fresh service per
    /// call would make the guard dead code.
    private static let service: ModelUpdateService<URLSessionModelUpdateClient>? = {
        ModelUpdateStore.production.map {
            ModelUpdateService(
                baseURL: ModelUpdateConfiguration.endpoint,
                client: URLSessionModelUpdateClient(),
                store: $0)
        }
    }()

    /// Runs one update check: fetch the manifest, and stage a newer model for
    /// the *next* launch. The running session never hot-swaps models — the
    /// loader picks the staged file up on the following launch.
    ///
    /// Concurrent firings are coalesced: when a check is already running, this
    /// returns immediately — the in-flight check already covers it.
    ///
    /// Synchronous and safe to call from the main actor: the detached
    /// utility-QoS task is spawned here, so the manifest fetch, hashing, and
    /// atomic stage structurally cannot run on the main actor, and the QoS /
    /// off-actor guarantee can't be lost by a future call site.
    static func checkForUpdates() {
        Task.detached(priority: .utility) {
            // nil when there is no Application Support directory — the same
            // no-op as before, now without allocating a service per firing.
            await service?.checkForUpdates()
        }
    }
}
