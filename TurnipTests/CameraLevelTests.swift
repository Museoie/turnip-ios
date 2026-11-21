import XCTest
@testable import Turnip

final class CameraLevelTests: XCTestCase {
    /// Gravity as the device frame reads it with the phone rolled `degrees` clockwise from
    /// upright portrait, as its holder sees the screen.
    private func level(rolledClockwise degrees: Double, inPlane: Double = 1) -> CameraLevel? {
        let radians = degrees * .pi / 180
        return CameraLevel(gravityX: inPlane * sin(radians), gravityY: -inPlane * cos(radians))
    }

    func testAnUprightPhoneIsLevel() throws {
        let level = try XCTUnwrap(CameraLevel(gravityX: 0, gravityY: -1))

        XCTAssertEqual(level.rollRadians, 0, accuracy: 1e-12)
        XCTAssertEqual(level.quarterTurns, 0)
        XCTAssertEqual(level.tiltDegrees, 0, accuracy: 1e-9)
    }

    /// The sign says which way: clockwise positive, counterclockwise negative.
    func testTheTiltIsSignedByTheWayThePhoneLeans() throws {
        let clockwise = try XCTUnwrap(level(rolledClockwise: 7))
        let counterclockwise = try XCTUnwrap(level(rolledClockwise: -7))

        XCTAssertEqual(clockwise.tiltDegrees, 7, accuracy: 1e-9)
        XCTAssertEqual(counterclockwise.tiltDegrees, -7, accuracy: 1e-9)
        XCTAssertEqual(clockwise.quarterTurns, 0)
        XCTAssertEqual(counterclockwise.quarterTurns, 0)
    }

    /// Held on its side or upside down, the phone is leveled against that way of holding it:
    /// the tilt is what is left over, never more than 45°.
    func testTheTiltIsMeasuredFromTheNearestWayOfHoldingThePhone() throws {
        let cases: [(roll: Double, quarterTurns: Int, tilt: Double)] = [
            (90, 1, 0), (95, 1, 5), (84, 1, -6), (-90, -1, 0), (-97, -1, -7),
            (176, 2, -4), (-176, -2, 4), (40, 0, 40), (50, 1, -40)
        ]
        for expected in cases {
            let level = try XCTUnwrap(level(rolledClockwise: expected.roll))
            XCTAssertEqual(level.quarterTurns, expected.quarterTurns, "\(expected.roll)°")
            XCTAssertEqual(level.tiltDegrees, expected.tilt, accuracy: 1e-9, "\(expected.roll)°")
        }
    }

    /// Pitched forward or back the roll reads the same: only the gravity left in the screen's
    /// plane shrinks.
    func testPitchLeavesTheRollAlone() throws {
        let pitched = try XCTUnwrap(level(rolledClockwise: 12, inPlane: 0.6))

        XCTAssertEqual(pitched.tiltDegrees, 12, accuracy: 1e-9)
    }

    /// Near flat the roll means nothing, and there is no reading.
    func testAPhoneNearFlatHasNoLevel() {
        XCTAssertNil(level(rolledClockwise: 12, inPlane: 0.4))
        XCTAssertNil(CameraLevel(gravityX: 0, gravityY: 0))
        XCTAssertNil(CameraLevel(gravityX: .nan, gravityY: -1))
        XCTAssertNotNil(level(rolledClockwise: 12, inPlane: 0.5 + 1e-9))
    }
}
