import Foundation

/// Where the app's turnip-farm lives: `TURNIP_FARM_ENDPOINT` in the main bundle's Info.plist, the
/// https base URL every contribution call and the vocabulary fetch resolve against
/// (`docs/CONTRIBUTION_DESIGN.md` §5). Kept apart from `ModelUpdateConfiguration`'s key so pointing
/// contribution at a farm doesn't also switch on the model poll, which waits on a promoted model.
///
/// A blank or non-https value leaves `endpoint` nil: every farm feature then stays hidden and the
/// app makes no farm call at all.
enum FarmConfiguration {
    static let infoPlistKey = "TURNIP_FARM_ENDPOINT"

    static var endpoint: URL? {
        parseEndpoint(Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    static func parseEndpoint(_ rawValue: String?) -> URL? {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
