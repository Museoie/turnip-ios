import Foundation

/// A trick-model release as the farm names it: `"trick-v1.3"`, or `"trick-v1.3-rb1"` for a
/// rollback that re-promotes an earlier artifact under a version of its own
/// (`MODEL_CONTRACT.md` §5).
///
/// An identifier, not an ordering. The client takes an update whenever the farm's current
/// version differs from the one it has (§4), so a rollback arrives like any other release.
struct ModelVersion: Codable, Hashable, Sendable {
    /// The version exactly as the manifest served it.
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
