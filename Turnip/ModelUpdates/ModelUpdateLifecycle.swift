import Foundation

/// Wires the OTA model-update service into the app lifecycle (issue #96).
///
/// The whole flow is inert until `TURNIP_MODEL_UPDATE_ENDPOINT` is configured:
/// with no endpoint `ModelUpdateConfiguration.endpoint` is nil and
/// `checkForUpdates` becomes a no-op with zero network traffic, so the v1
/// "nothing leaves the device" promise holds until a turnip-farm deployment
/// exists.
enum ModelUpdateLifecycle {
    /// Runs one update check: fetch the manifest, and stage a newer model for
    /// the *next* launch. The running session never hot-swaps models — the
    /// loader picks the staged file up on the following launch.
    ///
    /// Off the main actor by contract: callers must dispatch it from a
    /// detached task, since the manifest fetch, hashing, and atomic stage must
    /// not contend with UI work.
    static func checkForUpdates() async {
        guard let store = ModelUpdateStore.production else { return }
        let service = ModelUpdateService(
            baseURL: ModelUpdateConfiguration.endpoint,
            client: URLSessionModelUpdateClient(),
            store: store)
        await service.checkForUpdates()
    }
}
