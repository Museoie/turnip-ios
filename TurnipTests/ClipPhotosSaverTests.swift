import Foundation
import XCTest
@testable import Turnip

final class ClipPhotosSaverTests: XCTestCase {
    private func missingFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
    }

    func testSaveVideoThrowsMissingInputFileWithoutAskingForAuthorization() async {
        // The authorization closure traps if called: the missing-file check must
        // short-circuit before any Photos prompt.
        var saver = ClipPhotosSaver()
        saver.authorization = {
            XCTFail("authorization must not be requested for a missing file")
            return .denied(restricted: false)
        }

        do {
            try await saver.saveVideo(at: missingFileURL())
            XCTFail("expected missingInputFile")
        } catch let error as ClipPhotosSaveError {
            guard case .missingInputFile = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testSaveVideoThrowsTypedDenialWhenAuthorizationIsDenied() async throws {
        var saver = ClipPhotosSaver()
        saver.authorization = { .denied(restricted: false) }
        let url = missingFileURL()
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try await saver.saveVideo(at: url)
            XCTFail("expected authorizationDenied")
        } catch let error as ClipPhotosSaveError {
            XCTAssertEqual(error, .authorizationDenied(restricted: false))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testSaveVideoMarksARestrictedDenialSoTheUICanSkipSettings() async throws {
        var saver = ClipPhotosSaver()
        saver.authorization = { .denied(restricted: true) }
        let url = missingFileURL()
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try await saver.saveVideo(at: url)
            XCTFail("expected authorizationDenied")
        } catch let error as ClipPhotosSaveError {
            XCTAssertEqual(error, .authorizationDenied(restricted: true))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
