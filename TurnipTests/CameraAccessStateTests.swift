import AVFoundation
import XCTest
@testable import Turnip

final class CameraAccessStateTests: XCTestCase {
    func testAuthorizedVideoRow() {
        XCTAssertEqual(CameraAccessState(video: .authorized, audio: .authorized), .authorized)
        XCTAssertEqual(
            CameraAccessState(video: .authorized, audio: .restricted),
            .denied(restricted: true)
        )
        XCTAssertEqual(
            CameraAccessState(video: .authorized, audio: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            CameraAccessState(video: .authorized, audio: .denied),
            .denied(restricted: false)
        )
    }

    func testRestrictedVideoRow() {
        XCTAssertEqual(
            CameraAccessState(video: .restricted, audio: .authorized),
            .denied(restricted: true)
        )
        XCTAssertEqual(
            CameraAccessState(video: .restricted, audio: .restricted),
            .denied(restricted: true)
        )
        XCTAssertEqual(
            CameraAccessState(video: .restricted, audio: .notDetermined),
            .denied(restricted: true)
        )
        XCTAssertEqual(
            CameraAccessState(video: .restricted, audio: .denied),
            .denied(restricted: true)
        )
    }

    func testNotDeterminedVideoRow() {
        XCTAssertEqual(
            CameraAccessState(video: .notDetermined, audio: .authorized),
            .notDetermined
        )
        XCTAssertEqual(
            CameraAccessState(video: .notDetermined, audio: .restricted),
            .denied(restricted: true)
        )
        XCTAssertEqual(
            CameraAccessState(video: .notDetermined, audio: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            CameraAccessState(video: .notDetermined, audio: .denied),
            .notDetermined
        )
    }

    func testDeniedVideoRow() {
        XCTAssertEqual(
            CameraAccessState(video: .denied, audio: .authorized),
            .denied(restricted: false)
        )
        XCTAssertEqual(
            CameraAccessState(video: .denied, audio: .restricted),
            .denied(restricted: true)
        )
        XCTAssertEqual(
            CameraAccessState(video: .denied, audio: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            CameraAccessState(video: .denied, audio: .denied),
            .denied(restricted: false)
        )
    }

    func testRestrictedWinsOverNotDetermined() {
        // Branch order is load-bearing: a restricted side resolves to the
        // linkless denied screen even when the other side was never
        // prompted. Swapping the restricted and notDetermined arms would
        // silently change what that user sees, so pin the order here.
        XCTAssertEqual(
            CameraAccessState(video: .notDetermined, audio: .restricted),
            .denied(restricted: true)
        )
        XCTAssertEqual(
            CameraAccessState(video: .restricted, audio: .notDetermined),
            .denied(restricted: true)
        )
    }
}
