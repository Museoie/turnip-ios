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

    /// Each cross-fading layer's opacity is a function of the card's travel that spans the
    /// whole flight, crosses half exactly at its inflection, and holds near its start value
    /// until close to it. Checked for the shipped constants and for a sweep of others, since
    /// where the inflections sit and how steep the halves are is tuning, not behaviour.
    func testCrossfadeOpacityCrossesHalfAtTheInflectionAndSpansTheFlight() {
        let chrome = ExpansionFlightGeometry.chromeCrossfadeInflection
        let scrim = ExpansionFlightGeometry.scrimCrossfadeInflection
        let layers: [(inflection: CGFloat, steepness: CGFloat)] = [
            (chrome, ExpansionFlightGeometry.chromeCrossfadeSteepness),
            (scrim, ExpansionFlightGeometry.scrimCrossfadeSteepness),
            (0.2, 3), (0.5, 3), (0.8, 5)
        ]
        for (inflection, steepness) in layers {
            let opacity = {
                ExpansionFlightGeometry.crossfadeOpacity(progress: $0, inflection: inflection, steepness: steepness)
            }
            XCTAssertEqual(opacity(0), 0, accuracy: 0.0001)
            XCTAssertEqual(opacity(1), 1, accuracy: 0.0001)
            XCTAssertEqual(opacity(inflection), 0.5, accuracy: 0.0001)
            // Still within a few percent of its start value halfway to the inflection.
            XCTAssertLessThan(opacity(inflection / 2), 0.1)
            // Monotonic.
            var last: CGFloat = -1
            for step in 0...20 {
                let value = opacity(CGFloat(step) / 20)
                XCTAssertGreaterThanOrEqual(value, last)
                last = value
            }
        }
    }

    func testDismissDragMapsLinearlyOntoProgress() {
        let travel = ExpansionFlightGeometry.dismissTravel
        XCTAssertEqual(ExpansionFlightGeometry.progress(forDismissTranslation: 0), 1)
        XCTAssertEqual(ExpansionFlightGeometry.progress(forDismissTranslation: travel / 4), 0.75, accuracy: 0.0001)
        XCTAssertEqual(ExpansionFlightGeometry.progress(forDismissTranslation: travel * 2), 0)
        XCTAssertEqual(ExpansionFlightGeometry.progress(forDismissTranslation: -50), 1, "an upward drag stays put")
    }

    func testDismissCommitsPastTheDeadZoneOrWhileStillMovingDown() {
        XCTAssertTrue(ExpansionFlightGeometry.dismissCommits(translation: 13, predictedTranslation: 0))
        XCTAssertTrue(ExpansionFlightGeometry.dismissCommits(translation: 5, predictedTranslation: 6))
        XCTAssertFalse(ExpansionFlightGeometry.dismissCommits(translation: 12, predictedTranslation: 12))
        XCTAssertFalse(ExpansionFlightGeometry.dismissCommits(translation: 5, predictedTranslation: -20))
    }
}
