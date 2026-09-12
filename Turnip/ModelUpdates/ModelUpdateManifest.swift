import Foundation

/// The JSON document turnip-farm serves at `<baseURL>/api/models/current`.
///
/// This struct pins the contract the client, the store, and the server share:
/// the test suite decodes a manifest from a literal JSON payload, so any drift
/// in key names or shapes breaks the build loudly rather than silently.
struct ModelUpdateManifest: Codable, Equatable, Sendable {
    /// Release version, e.g. `"2026.09.10-1"`.
    let version: ModelVersion
    /// Where the model bytes live; must be `https` — the client refuses
    /// anything else before any bytes move.
    let downloadURL: URL
    /// Lowercase hex SHA-256 of the model bytes, verified before staging.
    let sha256: String
    /// Basename the staged file is stored under. Constrained to an allowlist
    /// (`[A-Za-z0-9._-]`) so a hostile manifest cannot escape the OTA
    /// directory via `../` or nested paths.
    let fileName: String
}
