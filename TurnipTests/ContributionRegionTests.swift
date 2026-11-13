import XCTest
@testable import Turnip

/// `ContributionRegion` pins (`docs/CONTRIBUTION_DESIGN.md` §8): contributing isn't offered on an
/// App Store storefront in the EU, the EEA or the UK, nor with no storefront to read, and is
/// offered elsewhere.
final class ContributionRegionTests: XCTestCase {
    func testEveryEUEEAAndUKStorefrontIsUnavailable() {
        let codes = [
            "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC", "HUN", "IRL",
            "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE",
            "ISL", "LIE", "NOR", "GBR"
        ]
        XCTAssertEqual(ContributionRegion.unavailableCountryCodes, Set(codes))
        for code in codes {
            XCTAssertFalse(ContributionRegion.isAvailable(storefrontCountryCode: code), code)
        }
    }

    func testLowercaseCodesMatchToo() {
        XCTAssertFalse(ContributionRegion.isAvailable(storefrontCountryCode: "gbr"))
    }

    func testOtherStorefrontsAreAvailable() {
        for code in ["USA", "CAN", "KOR", "JPN", "AUS", "CHE"] {
            XCTAssertTrue(ContributionRegion.isAvailable(storefrontCountryCode: code), code)
        }
    }

    func testNoStorefrontIsUnavailable() {
        XCTAssertFalse(ContributionRegion.isAvailable(storefrontCountryCode: nil))
    }
}
