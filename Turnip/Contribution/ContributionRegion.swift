import StoreKit

/// Where contributing is offered (`docs/CONTRIBUTION_DESIGN.md` §8): not on an App Store storefront
/// in the EU, the EEA or the UK, where the maintainer has switched contribution off for now. The
/// farm refuses consent and uploads from those countries too, by the request's country, as a
/// backstop (`BACKEND_DESIGN.md` §8.1).
///
/// The storefront is the App Store country of the Apple account, not where the iPhone is. With no
/// storefront to read, contributing isn't offered either: the country can't be shown to be one
/// where it is (the maintainer's call). That includes builds without an App Store account, such
/// as the simulator.
enum ContributionRegion {
    /// ISO 3166-1 alpha-3 codes, as `Storefront.countryCode` gives them.
    static let unavailableCountryCodes: Set<String> = [
        // The EU's 27 member states.
        "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC", "HUN", "IRL",
        "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE",
        // The rest of the EEA.
        "ISL", "LIE", "NOR",
        // The UK.
        "GBR"
    ]

    static func isAvailable(storefrontCountryCode code: String?) -> Bool {
        guard let code else { return false }
        return !unavailableCountryCodes.contains(code.uppercased())
    }

    static func isAvailableOnCurrentStorefront() async -> Bool {
        isAvailable(storefrontCountryCode: await Storefront.current?.countryCode)
    }

    /// Turns Contribute named clips off where contributing isn't offered, which also cancels what
    /// the outbox still holds. Run on every foreground, since the switch may have been turned on
    /// under another storefront.
    @MainActor
    static func turnOffContributingIfUnavailable(settings: TurnipSettingsStore) async {
        guard settings.contributesClips, !(await isAvailableOnCurrentStorefront()) else { return }
        settings.contributesClips = false
    }
}
