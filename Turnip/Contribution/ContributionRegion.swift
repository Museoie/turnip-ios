import StoreKit

/// Where contributing is offered (`docs/CONTRIBUTION_DESIGN.md` §8): not on an App Store storefront
/// in the EU, the EEA or the UK, where the maintainer has switched contribution off for now. The
/// farm refuses consent and uploads from those storefronts too, by the `storefront_country` the
/// app sends, as a backstop (`BACKEND_DESIGN.md` §8.1).
///
/// The storefront is the App Store country of the Apple account, not where the iPhone is. With no
/// storefront to read, contributing isn't offered either, and this is no longer only a judgment
/// call: the farm refuses a contribution that carries no `storefront_country` (`403
/// REGION_UNAVAILABLE`), so offering it would only queue clips the farm turns away. That includes
/// builds without an App Store account, such as the simulator.
enum ContributionRegion {
    /// Whether contributing is offered, and if not, why: the two reasons read differently, since
    /// a user with no App Store account isn't in a country contributing is closed to.
    enum Availability: Equatable {
        case available
        /// An EU, EEA or UK storefront.
        case unavailableHere
        /// No storefront to read.
        case needsAppStoreAccount
    }

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

    static func availability(storefrontCountryCode code: String?) -> Availability {
        guard let code else { return .needsAppStoreAccount }
        return unavailableCountryCodes.contains(code.uppercased()) ? .unavailableHere : .available
    }

    static func isAvailable(storefrontCountryCode code: String?) -> Bool {
        availability(storefrontCountryCode: code) == .available
    }

    static func currentAvailability() async -> Availability {
        availability(storefrontCountryCode: await Storefront.current?.countryCode)
    }

    static func isAvailableOnCurrentStorefront() async -> Bool {
        await currentAvailability() == .available
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
