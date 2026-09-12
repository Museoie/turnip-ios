import Foundation

/// Typed failures for the OTA model update flow.
///
/// The service never throws these to its caller — `checkForUpdates` catches
/// everything and records it on `lastError` — but they are typed (not stringly)
/// so callers and tests can discriminate on the failure kind.
///
/// `Sendable` so the actor can hand `lastError` across its boundary without a
/// Swift 6 concurrency error: the one non-trivial payload (`network`'s
/// underlying error) is boxed as a `String` description instead of the `Error`
/// itself, which is not `Sendable`.
enum ModelUpdateError: Error, Sendable {
    /// The endpoint or download URL was not `https`. Model bytes are trust
    /// material; they never move over plaintext.
    case endpointNotHTTPS
    /// The manifest failed validation (e.g. a hostile `fileName`). The staged
    /// model is untouched.
    case invalidManifest
    /// The downloaded bytes did not match the manifest's SHA-256. Nothing is
    /// staged — a corrupt model must never replace a working one.
    case checksumMismatch
    /// Any transport or decoding failure underneath the client. Recorded, not
    /// thrown, so a failed check is silent to the user and the previously
    /// staged model keeps serving. The underlying error is boxed as its
    /// `String` description — an `Error` is not `Sendable`, and this enum must
    /// stay `Sendable` to cross the service actor's boundary.
    case network(underlying: String)
}
