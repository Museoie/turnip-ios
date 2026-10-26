import CryptoKit
import Foundation

/// The farm's `video_id` for a Photos-backed video (`docs/CONTRIBUTION_DESIGN.md` §1.1): the
/// lowercase hex SHA-256 of `"turnip:phasset:" + localIdentifier`. Deterministic, so it is
/// recomputed after a reinstall rather than stored, and one-way, so the raw identifier never
/// leaves the device. Camera takes are saved to Photos first and take this path too.
enum VideoIdentity {
    static func videoID(forAssetIdentifier localIdentifier: String) -> String {
        sha256Hex(Data(("turnip:phasset:" + localIdentifier).utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
