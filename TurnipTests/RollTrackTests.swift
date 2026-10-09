import AVFoundation
import Foundation
import XCTest
@testable import Turnip

final class RollTrackTests: XCTestCase {
    /// A roll clearly off level and clearly one-sided, so a sign error can't pass as rounding.
    private let roll = 7.0 * .pi / 180

    /// Gravity in the device frame for a phone turned `degreesClockwise` from upright
    /// portrait, as the holder sees it: at 0 it points down the phone (0, -1), at 180 up it.
    private func gravity(degreesClockwise: Double) -> SIMD3<Double> {
        let radians = degreesClockwise * .pi / 180
        return SIMD3(sin(radians), -cos(radians), 0)
    }

    private func tilt(_ gravity: SIMD3<Double>, rotation: Int, front: Bool = false) -> Double? {
        RollTrack.tilt(
            gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z,
            videoRotationDegrees: rotation, isFrontCamera: front)
    }

    // MARK: - Gravity to tilt

    func testAnUprightPortraitPhoneIsLevelThroughEitherCamera() throws {
        let upright = gravity(degreesClockwise: 0)

        XCTAssertEqual(try XCTUnwrap(tilt(upright, rotation: 90)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tilt(upright, rotation: 90, front: true)), 0, accuracy: 1e-9)
    }

    /// The sign test, pinned to the Vision fixture's convention: the back camera on a phone
    /// rolled clockwise sees the world turned counterclockwise, the horizon's right end
    /// rising — a negative tilt, which `levelingRotation(forHorizonTilts:)` turns into the
    /// clockwise rotation that levels it.
    func testBackCameraRolledClockwiseReadsACounterclockwiseTilt() throws {
        let measured = try XCTUnwrap(tilt(gravity(degreesClockwise: 7), rotation: 90))

        XCTAssertEqual(measured, -roll, accuracy: 1e-9)
        let leveling = try XCTUnwrap(HorizonLeveler.levelingRotation(forHorizonTilts: [measured]))
        XCTAssertEqual(leveling, roll, accuracy: 1e-9)
    }

    /// The front camera looks the other way, so the same roll tilts its picture the other way.
    func testFrontCameraRolledClockwiseReadsAClockwiseTilt() throws {
        let measured = try XCTUnwrap(tilt(gravity(degreesClockwise: 7), rotation: 90, front: true))

        XCTAssertEqual(measured, roll, accuracy: 1e-9)
    }

    /// Upside-down portrait (a 270° connection): level at rest, and the same roll reads the
    /// same tilt, since the picture is upright either way.
    func testUpsideDownPortraitReadsLikeUprightPortrait() throws {
        XCTAssertEqual(try XCTUnwrap(tilt(gravity(degreesClockwise: 180), rotation: 270)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tilt(gravity(degreesClockwise: 187), rotation: 270)), -roll, accuracy: 1e-9)
    }

    /// The back camera's native landscape (0°): upright with the phone's top to the left,
    /// which is the phone turned a quarter counterclockwise from portrait.
    func testBackCameraLandscapeTopToTheLeft() throws {
        XCTAssertEqual(try XCTUnwrap(tilt(gravity(degreesClockwise: -90), rotation: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tilt(gravity(degreesClockwise: -83), rotation: 0)), -roll, accuracy: 1e-9)
    }

    func testNoTiltWhenTheCameraPointsAlongGravity() {
        XCTAssertNil(tilt(SIMD3(0, 0, -1), rotation: 90))
        XCTAssertNil(tilt(SIMD3(0.1, 0.1, 0.98), rotation: 90))
        XCTAssertNil(tilt(SIMD3(.nan, 0, 0), rotation: 90))
    }

    // MARK: - The track in a file

    /// Samples every tenth of a second with distinct tilts, read back over a window that
    /// starts and ends between samples: the samples in force inside it, in order. A
    /// sample stays in force until the next one starts — the file stores it that way,
    /// whatever duration the group was appended with — so the sample just before the
    /// window's start is in, and the one just after its end is out.
    func testTiltsReadBackTheSamplesInForceInsideTheWindow() async throws {
        let samples = (1...9).map { (time: Double($0) / 10, tilt: Double($0) / 100) }
        let url = try await TestVideoWriter.writeTestVideo(
            frameCount: 30, width: 64, height: 64, fps: 30, rollSamples: samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let tilts = try await RollTrack.tilts(
            in: AVURLAsset(url: url), window: TrickWindow(startTime: 0.25, endTime: 0.65))

        let expected = [0.02, 0.03, 0.04, 0.05, 0.06]
        XCTAssertEqual(try XCTUnwrap(tilts).count, expected.count)
        for (measured, wanted) in zip(tilts ?? [], expected) {
            XCTAssertEqual(measured, wanted, accuracy: 1e-9)
        }
    }

    /// No track at all (an imported video) is nil, so the caller can fall back; a track
    /// with nothing in the window is an empty list, which is an answer of its own.
    func testTiltsAreNilWithoutATrackAndEmptyWithoutSamplesInTheWindow() async throws {
        let plain = try await TestVideoWriter.writeTestVideo(frameCount: 30, width: 64, height: 64, fps: 30)
        defer { try? FileManager.default.removeItem(at: plain) }
        let early = try await TestVideoWriter.writeTestVideo(
            frameCount: 30, width: 64, height: 64, fps: 30, rollSamples: [(0.1, 0.01), (0.2, 0.02)])
        defer { try? FileManager.default.removeItem(at: early) }
        let window = TrickWindow(startTime: 0.5, endTime: 0.9)

        let withoutTrack = try await RollTrack.tilts(in: AVURLAsset(url: plain), window: window)
        let outsideWindow = try await RollTrack.tilts(in: AVURLAsset(url: early), window: window)

        XCTAssertNil(withoutTrack)
        XCTAssertEqual(outsideWindow, [])
    }

    // MARK: - The leveler's choice of source

    /// A take whose picture and track disagree: the track wins, since the picture's horizon
    /// is a guess and the track is the phone's own gravity reading.
    func testLevelerPrefersTheRollTrackOverThePicturesHorizon() async throws {
        let trackTilt = -2.0 * .pi / 180
        let url = try await HorizonVideoFixture.write(
            tilt: HorizonVideoFixture.tilt, width: 320, height: 180,
            rollSamples: (0..<30).map { (time: Double($0) / 30, tilt: trackTilt) })
        defer { try? FileManager.default.removeItem(at: url) }

        let rotation = try await ClipLeveler.levelingRotation(
            in: AVURLAsset(url: url), window: TrickWindow(startTime: 0, endTime: 1))

        XCTAssertEqual(try XCTUnwrap(rotation), -trackTilt, accuracy: 1e-6)
    }

    func testLevelerFallsBackToThePictureWithoutATrack() async throws {
        let url = try await HorizonVideoFixture.write(tilt: HorizonVideoFixture.tilt, width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: url) }

        let rotation = try await ClipLeveler.levelingRotation(
            in: AVURLAsset(url: url), window: TrickWindow(startTime: 0, endTime: 1))

        XCTAssertEqual(try XCTUnwrap(rotation), -HorizonVideoFixture.tilt, accuracy: 0.03)
    }
}
