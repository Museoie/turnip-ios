import XCTest
@testable import Turnip

/// The uncropping flight geometry both expansion containers draw with: the card's
/// window must start as exactly what the tile shows, end as the whole content, and
/// scale width and height by one factor the whole way.
final class ExpansionFlightGeometryTests: XCTestCase {
    private let tile = CGRect(x: 200, y: 100, width: 176, height: 176)
    private let destination = CGRect(x: 51, y: 129, width: 290, height: 515)

    func testStartsOnTheTileShowingTheFocusRectsCenterSquare() {
        let focus = CGRect(origin: .zero, size: destination.size)
        let geometry = ExpansionFlightGeometry.resolve(
            progress: 0, sourceFrame: tile, destination: destination, focus: focus)
        XCTAssertEqual(geometry.rect, tile)
        // A square tile aspect-fills the portrait focus rect, so it shows its center square.
        XCTAssertEqual(geometry.region.width, 290, accuracy: 0.001)
        XCTAssertEqual(geometry.region.height, 290, accuracy: 0.001)
        XCTAssertEqual(geometry.region.midX, focus.midX, accuracy: 0.001)
        XCTAssertEqual(geometry.region.midY, focus.midY, accuracy: 0.001)
        XCTAssertEqual(geometry.scale, 176.0 / 290.0, accuracy: 0.0001)
    }

    func testEndsOnTheDestinationShowingTheWholeContent() {
        let focus = CGRect(x: 40, y: 80, width: 120, height: 200)
        let geometry = ExpansionFlightGeometry.resolve(
            progress: 1, sourceFrame: tile, destination: destination, focus: focus)
        XCTAssertEqual(geometry.rect, destination)
        XCTAssertEqual(geometry.region, CGRect(origin: .zero, size: destination.size))
        XCTAssertEqual(geometry.scale, 1, accuracy: 0.0001)
    }

    func testRegionAlwaysMapsOntoRectByOneUniformScale() {
        let focus = CGRect(x: 40, y: 80, width: 120, height: 200)
        for step in 0...10 {
            let progress = CGFloat(step) / 10
            let geometry = ExpansionFlightGeometry.resolve(
                progress: progress, sourceFrame: tile, destination: destination, focus: focus)
            XCTAssertEqual(geometry.region.width * geometry.scale, geometry.rect.width, accuracy: 0.001)
            XCTAssertEqual(geometry.region.height * geometry.scale, geometry.rect.height, accuracy: 0.001)
        }
    }

    func testSubFocusRectStartsOnItsOwnCenterSquare() {
        let focus = CGRect(x: 40, y: 80, width: 120, height: 200)
        let geometry = ExpansionFlightGeometry.resolve(
            progress: 0, sourceFrame: tile, destination: destination, focus: focus)
        XCTAssertEqual(geometry.region.width, 120, accuracy: 0.001)
        XCTAssertEqual(geometry.region.height, 120, accuracy: 0.001)
        XCTAssertEqual(geometry.region.midX, 100, accuracy: 0.001)
        XCTAssertEqual(geometry.region.midY, 180, accuracy: 0.001)
    }

    func testDegenerateFocusFallsBackToTheWholeContent() {
        let geometry = ExpansionFlightGeometry.resolve(
            progress: 0, sourceFrame: tile, destination: destination, focus: .zero)
        XCTAssertEqual(geometry.region.width, 290, accuracy: 0.001)
        XCTAssertEqual(geometry.region.height, 290, accuracy: 0.001)
    }

    func testScrubEasingIsSymmetricAndBounded() {
        XCTAssertEqual(FlightScrubber.easeInOut(0), 0, accuracy: 0.0001)
        XCTAssertEqual(FlightScrubber.easeInOut(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FlightScrubber.easeInOut(1), 1, accuracy: 0.0001)
        XCTAssertLessThan(FlightScrubber.easeInOut(0.25), 0.25)
        XCTAssertGreaterThan(FlightScrubber.easeInOut(0.75), 0.75)
    }

    /// A dragged dismiss plays the button's cross-fade by travel: the chrome is gone once
    /// the card has travelled the first `crossfadeShare` of the way back, the presenter
    /// under the scrim only starts returning once `crossfadeShare` of the travel remains,
    /// and at the midpoint the card sits (all but) alone over the backdrop — exactly alone
    /// when the windows don't overlap, within a few percent when they do.
    func testDragCrossfadeMapsTheFadeWindowsOntoTravel() {
        let share = CGFloat(ExpansionFlightGeometry.crossfadeShare)
        let open = ExpansionFlightGeometry.dragCrossfade(progress: 1)
        XCTAssertEqual(open.chrome, 1, accuracy: 0.0001)
        XCTAssertEqual(open.scrim, 1, accuracy: 0.0001)
        let tile = ExpansionFlightGeometry.dragCrossfade(progress: 0)
        XCTAssertEqual(tile.chrome, 0, accuracy: 0.0001)
        XCTAssertEqual(tile.scrim, 0, accuracy: 0.0001)

        // The leaving window's end: chrome gone. The arriving window's start: scrim intact.
        let leavingEnd = ExpansionFlightGeometry.dragCrossfade(progress: 1 - share)
        XCTAssertEqual(leavingEnd.chrome, 0, accuracy: 0.0001)
        let arrivingStart = ExpansionFlightGeometry.dragCrossfade(progress: share)
        XCTAssertEqual(arrivingStart.scrim, 1, accuracy: 0.0001)

        let halfwayOut = ExpansionFlightGeometry.dragCrossfade(progress: 1 - share / 2)
        XCTAssertLessThan(halfwayOut.chrome, 0.5)
        XCTAssertGreaterThan(halfwayOut.scrim, 0.95)

        let between = ExpansionFlightGeometry.dragCrossfade(progress: 0.5)
        XCTAssertLessThan(between.chrome, 0.05)
        XCTAssertGreaterThan(between.scrim, 0.95)

        let halfwayIn = ExpansionFlightGeometry.dragCrossfade(progress: share / 2)
        XCTAssertLessThan(halfwayIn.chrome, 0.05)
        XCTAssertGreaterThan(halfwayIn.scrim, 0.5)
    }
}
