import XCTest
@testable import Turnip

/// Pins the guard `VideoTileView.load(targetSize:replacingCurrentImage:)` runs before issuing a
/// thumbnail request. A tile's `@State` combination is unreachable without a view host, so the
/// decision is the seam.
@MainActor
final class VideoTileRequestDecisionTests: XCTestCase {
    func testAnEmptyTileRequestsOnAppearance() {
        XCTAssertTrue(
            VideoTileView.shouldRequestImage(
                hasImage: false, imageIsDegraded: false, hasRequestInFlight: false,
                loadedRevision: 0, revision: 0, replacingCurrentImage: false
            )
        )
    }

    func testADegradedImageIsRequestedAgainOnAppearance() {
        XCTAssertTrue(
            VideoTileView.shouldRequestImage(
                hasImage: true, imageIsDegraded: true, hasRequestInFlight: false,
                loadedRevision: 0, revision: 0, replacingCurrentImage: false
            )
        )
    }

    func testAFinalImageAtTheCurrentRevisionIsNotRequestedAgain() {
        XCTAssertFalse(
            VideoTileView.shouldRequestImage(
                hasImage: true, imageIsDegraded: false, hasRequestInFlight: false,
                loadedRevision: 2, revision: 2, replacingCurrentImage: false
            )
        )
    }

    func testAnInFlightRequestIsNotDuplicatedOnAppearance() {
        XCTAssertFalse(
            VideoTileView.shouldRequestImage(
                hasImage: false, imageIsDegraded: false, hasRequestInFlight: true,
                loadedRevision: 0, revision: 0, replacingCurrentImage: false
            )
        )
    }

    func testAFinalImageFromAnEarlierRevisionIsRequestedAgainOnAppearance() {
        // The replacement request was cancelled by a scroll before it delivered: the image on screen
        // is final-looking, no request is in flight, and this is the only path left that can repaint it.
        XCTAssertTrue(
            VideoTileView.shouldRequestImage(
                hasImage: true, imageIsDegraded: false, hasRequestInFlight: false,
                loadedRevision: 0, revision: 1, replacingCurrentImage: false
            )
        )
    }

    func testAReplacementIsIssuedOverAFinalImageAtTheCurrentRevision() {
        XCTAssertTrue(
            VideoTileView.shouldRequestImage(
                hasImage: true, imageIsDegraded: false, hasRequestInFlight: false,
                loadedRevision: 2, revision: 2, replacingCurrentImage: true
            )
        )
    }

    func testAReplacementIsIssuedEvenWhileAnEarlierRequestIsStillInFlight() {
        // The replacing path cancels what it finds before requesting, so an in-flight request is not
        // a reason to skip it.
        XCTAssertTrue(
            VideoTileView.shouldRequestImage(
                hasImage: true, imageIsDegraded: true, hasRequestInFlight: true,
                loadedRevision: 0, revision: 1, replacingCurrentImage: true
            )
        )
    }
}
