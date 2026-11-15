import XCTest
@testable import Turnip

/// `FarmAccountSection.waitingMessage` pins (`docs/CONTRIBUTION_DESIGN.md` §5.4): Settings' waiting
/// row says what a stuck queue waits for, a sign-in first, then an agreement the farm asked for
/// again.
final class FarmAccountSectionTests: XCTestCase {
    func testAQueueThatCanSendSaysOnlyWhatWaits() {
        XCTAssertEqual(
            FarmAccountSection.waitingMessage(count: 1, isSignedIn: true, hasConsented: true),
            String(localized: "1 clip waiting to send."))
        XCTAssertEqual(
            FarmAccountSection.waitingMessage(count: 3, isSignedIn: true, hasConsented: true),
            String(localized: "3 clips waiting to send."))
    }

    func testASignedOutQueueAsksForASignIn() {
        let message = FarmAccountSection.waitingMessage(count: 2, isSignedIn: false, hasConsented: false)
        XCTAssertTrue(message.hasSuffix(String(localized: "Sign in to finish.")))
        XCTAssertFalse(message.contains(ContributionDisclosure.agreeToFinish))
    }

    /// The farm answered `CONSENT_REQUIRED`, so the agreement here was withdrawn: the row says the
    /// next save asks for it.
    func testAQueueWaitingForTheAgreementSaysSo() {
        let message = FarmAccountSection.waitingMessage(count: 2, isSignedIn: true, hasConsented: false)
        let waiting = String(localized: "2 clips waiting to send.")
        XCTAssertEqual(message, "\(waiting) \(ContributionDisclosure.agreeToFinish)")
    }
}
