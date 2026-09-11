import XCTest
@testable import Turnip

/// Pins which thumbnail deliveries mark a tile's revision as loaded. The handler that consumes this
/// runs inside `VideoTileView.load(targetSize:replacingCurrentImage:)` against `@State`, which is
/// unreachable without a view host, so the decision is the seam.
@MainActor
final class VideoTileDeliveryTests: XCTestCase {
    func testAFinalImageLoadsTheRequestedRevision() {
        XCTAssertTrue(VideoTileView.deliveryLoadsRevision(hasResult: true, isDegraded: false))
    }

    func testAFinalCallbackCarryingNoImageDoesNotLoadTheRequestedRevision() {
        // A failed replacement request ends without repainting: the previous revision's thumbnail is
        // still on screen, and this is the only signal that keeps the appearance path open for it.
        XCTAssertFalse(VideoTileView.deliveryLoadsRevision(hasResult: false, isDegraded: false))
    }

    func testADegradedImageDoesNotLoadTheRequestedRevision() {
        XCTAssertFalse(VideoTileView.deliveryLoadsRevision(hasResult: true, isDegraded: true))
    }

    func testADegradedCallbackCarryingNoImageDoesNotLoadTheRequestedRevision() {
        XCTAssertFalse(VideoTileView.deliveryLoadsRevision(hasResult: false, isDegraded: true))
    }
}
