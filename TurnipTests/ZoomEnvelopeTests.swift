import CoreGraphics
import XCTest
@testable import Turnip

/// Auto follow's zoom envelope: the room the athlete needs, reached for ahead, held through
/// small changes, and eased, closing in slower than it opens.
final class ZoomEnvelopeTests: XCTestCase {
    private let envelope = ZoomEnvelope()
    private let times = (0..<80).map { Double($0) / 10 }

    func testASteadyNeedHoldsOneWidth() {
        let widths = envelope.widths(times: times, needs: times.map { _ in 400 })

        XCTAssertEqual(widths.count, times.count)
        for width in widths { XCTAssertEqual(width, 400, accuracy: 1e-6) }
        XCTAssertEqual(envelope.zoomCount(times: times, needs: times.map { _ in 400 }), 0)
    }

    /// Changes smaller than the dead zone are ignored.
    func testSmallChangesAreIgnored() {
        let needs: [CGFloat?] = times.indices.map { $0 % 2 == 0 ? 400 : 440 }

        XCTAssertEqual(envelope.zoomCount(times: times, needs: needs), 0)
        let widths = envelope.widths(times: times, needs: needs)
        XCTAssertEqual(widths.max() ?? 0, widths.min() ?? 0, accuracy: 1e-6)
    }

    /// A reach for room widens the crop before it, takes it all at its height, and lets go
    /// more slowly than it came.
    func testAReachWidensTheCropAheadOfIt() {
        let needs: [CGFloat?] = times.map { $0 >= 3 && $0 < 3.3 ? 600 : 400 }

        let widths = envelope.widths(times: times, needs: needs)

        XCTAssertEqual(envelope.zoomCount(times: times, needs: needs), 2)
        XCTAssertGreaterThan(widths[25], 440, "widening half a second ahead")
        XCTAssertEqual(widths.max() ?? 0, 600, accuracy: 60)
        let peak = widths.firstIndex(of: widths.max() ?? 0) ?? 0
        XCTAssertGreaterThan(peak, 25)
    }

    /// The crop closes in at most half as fast as it opens out (to within the overlap of the
    /// two eases' tails).
    func testAZoomInIsAtMostHalfAsFastAsAZoomOut() {
        let needs: [CGFloat?] = times.map { $0 >= 1.5 && $0 < 5 ? 600 : 400 }
        let fine = stride(from: 0.0, through: 7.9, by: 0.01).map { $0 }
        let widths = envelope.widths(times: times, needs: needs)
        XCTAssertEqual(widths.count, times.count)
        // The envelope's shape between samples, from the same steps on a finer grid.
        let fineNeeds: [CGFloat?] = fine.map { $0 >= 1.5 && $0 < 5 ? 600 : 400 }
        let fineWidths = envelope.widths(times: fine, needs: fineNeeds)
        let rates = zip(fineWidths, fineWidths.dropFirst()).map { log($1 / $0) / 0.01 }

        let opening = rates.max() ?? 0, closing = -(rates.min() ?? 0)
        XCTAssertGreaterThan(opening, 0)
        XCTAssertLessThanOrEqual(closing, opening * 0.5 * 1.01)
        XCTAssertGreaterThan(closing, opening * 0.4, "and closes in")
    }

    /// A sample that located nothing takes its neighbours' room; with nothing located there is
    /// no envelope.
    func testUnlocatedSamplesTakeTheirNeighbours() {
        var needs: [CGFloat?] = times.map { _ in 500 }
        needs[10] = nil
        needs[0] = nil

        let widths = envelope.widths(times: times, needs: needs)

        XCTAssertEqual(widths[10], 500, accuracy: 1e-6)
        XCTAssertEqual(widths[0], 500, accuracy: 1e-6)
        XCTAssertTrue(envelope.widths(times: times, needs: times.map { _ in nil }).isEmpty)
    }
}
