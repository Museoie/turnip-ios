import XCTest
@testable import Turnip

/// Guards for `ClipShareButton.isShareable` (issue #12): the share sheet must never be
/// offered for a URL it can't hand off. Each test discriminates one half of the guard —
/// dropping the existence check fails `testNotShareableWhenFileIsMissing`, dropping the
/// file-URL check fails `testNotShareableWhenURLIsNotAFileURL`.
final class ClipShareTests: XCTestCase {
    func testShareableWhenFileExists() throws {
        let url = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ClipShareButton.isShareable(fileURL: url))
    }

    func testNotShareableWhenFileIsMissing() {
        // Never created: the export's scratch file was cleaned up (or never written).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-share-test-\(UUID().uuidString).mp4")
        XCTAssertFalse(ClipShareButton.isShareable(fileURL: url))
    }

    func testNotShareableWhenURLIsNotAFileURL() throws {
        // A remote URL would share a link, not the on-device video — the design doc's
        // whole point is that the OS moves the file, zero server involvement.
        // Built over a path that exists on disk, so this test discriminates the
        // file-URL half of the guard: deleting `isFileURL` would let it pass.
        let existing = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: existing) }
        let remote = URL(string: "https://example.com" + existing.path)!
        XCTAssertFalse(ClipShareButton.isShareable(fileURL: remote))
    }

    private static func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-share-test-\(UUID().uuidString).mp4")
        guard FileManager.default.createFile(atPath: url.path, contents: Data([0x00])) else {
            throw XCTSkip("could not create temp file for shareability test")
        }
        return url
    }
}
