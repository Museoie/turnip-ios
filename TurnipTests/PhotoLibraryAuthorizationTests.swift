import Photos
import XCTest
@testable import Turnip

final class PhotoLibraryAuthorizationTests: XCTestCase {
    func testMapsEachPhotoKitStatus() {
        XCTAssertEqual(PhotoLibraryAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(PhotoLibraryAuthorization(.authorized), .authorized)
        XCTAssertEqual(PhotoLibraryAuthorization(.limited), .limited)
        XCTAssertEqual(PhotoLibraryAuthorization(.denied), .denied(restricted: false))
        XCTAssertEqual(PhotoLibraryAuthorization(.restricted), .denied(restricted: true))
    }

    func testOnlyAuthorizedAndLimitedCanReadLibrary() {
        XCTAssertTrue(PhotoLibraryAuthorization.authorized.canReadLibrary)
        XCTAssertTrue(PhotoLibraryAuthorization.limited.canReadLibrary)
        XCTAssertFalse(PhotoLibraryAuthorization.notDetermined.canReadLibrary)
        XCTAssertFalse(PhotoLibraryAuthorization.denied(restricted: false).canReadLibrary)
        XCTAssertFalse(PhotoLibraryAuthorization.denied(restricted: true).canReadLibrary)
    }
}
