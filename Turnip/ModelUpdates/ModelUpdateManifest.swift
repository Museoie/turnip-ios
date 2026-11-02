import Foundation

/// The trick-model manifest turnip-farm serves at `<baseURL>/api/models/current`
/// (`MODEL_CONTRACT.md` §1).
///
/// Decodes only the fields the update acts on. The rest (`output_desc`, `vocabulary`,
/// `name_metrics` and the others) stays in `json`, the document exactly as served, which the store
/// keeps beside the artifact for whatever reads it later. The farm's descriptor and metric fields
/// are free-form JSONB, so a change in their shape can't stop a model from arriving.
///
/// `r2_key` is never decoded: it names the artifact's place in the farm's bucket, slashes and
/// all, and the store names its files after `version` instead.
struct ModelUpdateManifest: Sendable {
    let version: ModelVersion
    /// The presigned R2 GET the artifact downloads from. It expires 15 minutes after the farm
    /// served it, so the copy kept in `json` is provenance, never something to fetch.
    let url: URL
    /// Lowercase hex SHA-256 of the artifact's bytes, checked before anything is staged.
    let sha256: String
    /// The artifact's length in bytes, checked with `sha256`; `nil` when the farm has none.
    let byteSize: Int?
    /// The oldest app version the model works with, as dotted numbers (`"0.2.0"`); `nil` when
    /// it works with all of them.
    let minClientVersion: String?
    /// The manifest exactly as the farm served it.
    let json: Data

    /// Decodes the farm's manifest. Anything that doesn't decode is `invalidManifest`.
    init(json: Data) throws {
        let fields: ManifestFields
        do {
            fields = try JSONDecoder().decode(ManifestFields.self, from: json)
        } catch {
            throw ModelUpdateError.invalidManifest
        }
        version = fields.version
        url = fields.url
        sha256 = fields.sha256
        byteSize = fields.byteSize
        minClientVersion = fields.minClientVersion
        self.json = json
    }

    /// Whether an app at `clientVersion` (its `CFBundleShortVersionString`) may take this model:
    /// the manifest names no minimum, or the app is at least that minimum, compared as dotted
    /// numbers with missing components counting as 0 (`"1.1"` is `"1.1.0"`). A version on either
    /// side that isn't dotted numbers can't be compared, so the model is skipped.
    func admits(clientVersion: String?) -> Bool {
        guard let minClientVersion else { return true }
        guard let minimum = Self.numericComponents(minClientVersion),
              let client = clientVersion.flatMap(Self.numericComponents)
        else { return false }
        let width = max(minimum.count, client.count)
        let padded = { (parts: [Int]) in parts + Array(repeating: 0, count: width - parts.count) }
        return !padded(client).lexicographicallyPrecedes(padded(minimum))
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in
            part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        return numbers.count == parts.count ? numbers : nil
    }
}

/// The manifest fields the update acts on, under the farm's keys.
private struct ManifestFields: Decodable {
    let version: ModelVersion
    let url: URL
    let sha256: String
    let byteSize: Int?
    let minClientVersion: String?

    enum CodingKeys: String, CodingKey {
        case version, url, sha256
        case byteSize = "byte_size"
        case minClientVersion = "min_client_version"
    }
}
