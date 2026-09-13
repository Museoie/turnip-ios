import AVFoundation
import XCTest
@testable import Turnip

/// Assertions that only mean anything at submission time: the privacy manifest must actually
/// be in the app bundle (a dropped resource phase would keep CI green), and the export-compliance
/// flag must say what `docs/PRIVACY.md` claims it says.
///
/// `TurnipTests` is a hosted unit-test bundle, so `Bundle.main` here *is* the host app bundle.
final class PrivacyComplianceTests: XCTestCase {
    /// One line that discriminates: remove `PrivacyInfo.xcprivacy` from the bundle and this
    /// goes red; the PR-body inference from XcodeGen defaults would not.
    func testPrivacyManifestIsInAppBundle() {
        XCTAssertNotNil(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy must be copied into the app bundle — the manifest is fiction without it")
    }

    /// `docs/PRIVACY.md` asserts `ITSAppUsesNonExemptEncryption` is `NO`; assert the same thing
    /// the submitter will be asked, against the shipped plist.
    func testExportComplianceFlagIsNo() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool,
            false,
            "docs/PRIVACY.md claims ITSAppUsesNonExemptEncryption is NO")
    }

    /// The temp export's lifetime is the resolved asset's lifetime on `VideoLibraryViewModel.path`:
    /// popping the `SelectedVideo` must delete the file even though no diagnostic ever ran.
    /// (Browse-and-back-out is the dominant interaction, not an edge case.)
    @MainActor
    func testPoppingSelectedVideoDeletesItsTempExport() {
        let url = URL.temporaryDirectory.appending(
            path: "\(PhotoVideoResolver.temporaryExportFilenamePrefix)\(UUID().uuidString).mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        defer { try? FileManager.default.removeItem(at: url) }

        let viewModel = VideoLibraryViewModel()
        viewModel.path = [SelectedVideo(assetIdentifier: "test", asset: AVURLAsset(url: url), duration: 1)]
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "appending must not delete the export")

        viewModel.path = []
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "popping the SelectedVideo must delete its temp export")
    }

    /// The path-shrink cleanup must leave ordinary Photos videos alone: the asset points into
    /// the Photos container, and `deleteTemporaryExport` discriminates on the tmp/ prefix.
    @MainActor
    func testPoppingSelectedVideoIgnoresPhotosContainerAsset() {
        let url = URL(filePath: "/dev/null")
        let viewModel = VideoLibraryViewModel()
        viewModel.path = [SelectedVideo(assetIdentifier: "test", asset: AVURLAsset(url: url), duration: 1)]

        viewModel.path = []
        // Nothing to assert on the filesystem for /dev/null — the point is the pop path
        // runs without touching non-export assets (no throw, no delete attempt).
    }
}
