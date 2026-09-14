import Foundation

/// The single build-time config point for OTA updates.
///
/// Reads `TURNIP_MODEL_UPDATE_ENDPOINT` from the main bundle's Info.plist: the
/// https base URL of a turnip-farm deployment, e.g.
/// `https://models.turnip.example`. The service polls
/// `<baseURL>/api/models/current` against it.
///
/// The key is empty in the committed Info.plist — there is no turnip-farm
/// deployment to point at yet — so `endpoint` is nil and the update service is
/// inert: `checkForUpdates` becomes a no-op with zero network traffic, keeping
/// the v1 "nothing leaves the device" promise. When turnip-farm exists, set the
/// key (e.g. via an xcconfig) and the service activates with no code change.
/// https is enforced here *and* in the client: defense in depth for bytes the
/// loader will mmap and execute.
enum ModelUpdateConfiguration {
    /// The Info.plist key the endpoint is read from.
    static let infoPlistKey = "TURNIP_MODEL_UPDATE_ENDPOINT"

    /// The configured endpoint, or `nil` when the key is absent, blank, or not
    /// an https URL — in all of which cases OTA updates stay disabled.
    static var endpoint: URL? {
        parseEndpoint(
            Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    /// The raw-value → URL rule, factored pure so tests can exercise the
    /// absent/blank/non-https cases without a bundle on disk.
    static func parseEndpoint(_ rawValue: String?) -> URL? {
        guard let raw = rawValue?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            url.scheme?.lowercased() == "https"
        else {
            return nil
        }
        return url
    }
}
