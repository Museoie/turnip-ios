import Foundation

/// Wires the OTA model-update service into the app lifecycle.
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

    /// Runs one update check: fetch the manifest, and stage a newer
    /// trick-detection model for a *later* launch. The running session never
    /// hot-swaps models.
    ///
    /// Concurrent firings are coalesced: a check that starts while another is
    /// in flight is dropped by the service — the in-flight check covers it.
    ///
    /// Synchronous and safe to call from the main actor: the detached
    /// utility-QoS task is spawned here, so the manifest fetch, hashing, and
    /// atomic stage structurally cannot run on the main actor, and the QoS /
    /// off-actor guarantee can't be lost by a future call site.
    static func checkForUpdates() {
        Task.detached(priority: .utility) {
            // nil when there is no Application Support directory: nothing to do.
            await service?.checkForUpdates()
        }
    }
}
