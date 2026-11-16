import CoreGraphics
import Foundation
import XCTest
@testable import Turnip

/// The archive keeps a video's pose until the app is deleted, so analyzing it again reads the
/// frames instead of scoring them. These pin what reuse depends on: the frames come back whole,
/// with the spacing and size they were scored at, only for the video they were scored from, and
/// whatever a run does with them leaves the entry as it was.
final class VideoPoseArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-pose-archive-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func pose(count: Int, interval: TimeInterval = 0.1) throws -> PartialPoseFrames {
        try PartialPoseFrames(
            frames: (0..<count).map { MultiPoseFrame(single: PoseFixture.body(index: $0, hip: (x: 0.5, y: 0.5))) },
            interval: interval, renderedPixelSize: CGSize(width: 48, height: 64))
    }

    func testAKeptPoseComesBackWithItsSpacingAndSize() throws {
        let archive = VideoPoseArchive(directory: directory)
        let kept = try pose(count: 5, interval: 0.1)
        // A real identifier's shape: slashes, which the entry's file name can't carry as they are.
        archive.keep(kept, for: "4E2B-91A0/L0/001", duration: 3.5)

        let read = try XCTUnwrap(archive.pose(for: "4E2B-91A0/L0/001", duration: 3.5))
        XCTAssertEqual(try read.store.loadAll().map(\.timestamp), try kept.store.loadAll().map(\.timestamp))
        XCTAssertEqual(read.interval, 0.1)
        XCTAssertEqual(read.renderedPixelSize, CGSize(width: 48, height: 64))
    }

    /// A video trimmed in Photos keeps its identifier but not its length: its old pose is passed
    /// over. A container's rounding is not a trim.
    func testAPoseIsOnlyForTheVideoItWasScoredFrom() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 3), for: "video", duration: 10)

        XCTAssertNotNil(archive.pose(for: "video", duration: 10.1))
        XCTAssertNil(archive.pose(for: "video", duration: 9), "a trimmed video read its untrimmed pose")
        XCTAssertNil(archive.pose(for: "another video", duration: 10))
    }

    func testKeepingAgainReplacesTheEntry() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 3), for: "video", duration: 10)
        archive.keep(try pose(count: 6, interval: 0.2), for: "video", duration: 10)

        let read = try XCTUnwrap(archive.pose(for: "video", duration: 10))
        XCTAssertEqual(read.store.count, 6)
        XCTAssertEqual(read.interval, 0.2)
    }

    /// The pose handed out is in a store of its own: a run that discards it leaves the entry.
    func testTheEntryOutlivesTheStoreItHandsOut() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 3), for: "video", duration: 10)

        try XCTUnwrap(archive.pose(for: "video", duration: 10)).store.discard()
        XCTAssertEqual(archive.pose(for: "video", duration: 10)?.store.count, 3)
    }

    func testAPoseWithNoFramesIsNotKept() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 0), for: "video", duration: 10)

        XCTAssertNil(archive.pose(for: "video", duration: 10))
    }

    /// It can always be scored again from the video, so it stays out of device backups.
    func testTheArchiveIsLeftOutOfBackups() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 2), for: "video", duration: 10)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testNoDirectoryKeepsNothing() throws {
        let archive = VideoPoseArchive(directory: nil)
        archive.keep(try pose(count: 2), for: "video", duration: 10)

        XCTAssertNil(archive.pose(for: "video", duration: 10))
    }
}
