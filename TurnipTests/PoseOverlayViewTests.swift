import CoreGraphics
import XCTest
@testable import Turnip

final class PoseOverlayViewTests: XCTestCase {
    func testOverlayPointScalesNormalizedKeypointsWithoutClamping() {
        let inside = PoseKeypoint(name: "nose", y: 0.25, x: 0.5, confidence: 0.9)
        let padded = PoseKeypoint(name: "left_ankle", y: 1.2, x: -0.1, confidence: 0.9)
        let size = CGSize(width: 200, height: 100)

        XCTAssertEqual(PoseOverlayView.point(for: inside, in: size), CGPoint(x: 100, y: 25))
        XCTAssertEqual(PoseOverlayView.point(for: padded, in: size).x, -20, accuracy: 0.001)
        XCTAssertEqual(PoseOverlayView.point(for: padded, in: size).y, 120, accuracy: 0.001)
    }

    func testSkeletonEdgesOnlyNameRealKeypoints() {
        let names = Set(PoseKeypoint.names)
        for edge in PoseOverlayView.edges {
            XCTAssertTrue(names.contains(edge.0), "\(edge.0) is not a MoveNet keypoint")
            XCTAssertTrue(names.contains(edge.1), "\(edge.1) is not a MoveNet keypoint")
        }
    }
}
