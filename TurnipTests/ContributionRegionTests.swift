import XCTest
@testable import Turnip

/// `ContributionRegion` pins (`docs/CONTRIBUTION_DESIGN.md` §8): contributing isn't offered on an
/// App Store storefront in the EU, the EEA or the UK, nor with no storefront to read, which the
/// farm refuses, and is offered elsewhere. The two refusals say different things.
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

    /// Fails closed: the farm refuses a contribution with no `storefront_country`.
    func testNoStorefrontIsUnavailable() {
        XCTAssertFalse(ContributionRegion.isAvailable(storefrontCountryCode: nil))
        XCTAssertEqual(ContributionRegion.availability(storefrontCountryCode: nil), .needsAppStoreAccount)
    }

    func testEachStorefrontGetsItsReason() {
        XCTAssertEqual(ContributionRegion.availability(storefrontCountryCode: "USA"), .available)
        XCTAssertEqual(ContributionRegion.availability(storefrontCountryCode: "FRA"), .unavailableHere)
        XCTAssertEqual(ContributionRegion.availability(storefrontCountryCode: "gbr"), .unavailableHere)
    }

    /// A user with no App Store account isn't told their country is closed to contributing.
    func testNoStorefrontIsNotCalledACountryRefusal() {
        XCTAssertEqual(
            ContributionDisclosure.unavailable(.needsAppStoreAccount), ContributionDisclosure.needsAppStoreAccount)
        XCTAssertEqual(ContributionDisclosure.unavailable(.unavailableHere), ContributionDisclosure.unavailableHere)
        XCTAssertNotEqual(ContributionDisclosure.needsAppStoreAccount, ContributionDisclosure.unavailableHere)
    }
}
