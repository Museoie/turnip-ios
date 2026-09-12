import Foundation

/// Typed failures for the OTA model update flow.
///
/// The service never throws these to its caller — `checkForUpdates` catches
/// everything and records it on `lastError` — but they are typed (not stringly)
/// so callers and tests can discriminate on the failure kind.
enum ModelUpdateError: Error {
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
    /// staged model keeps serving.
    case network(underlying: Error)
}
