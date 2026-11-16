import AVFoundation
import CoreGraphics
import Foundation
import XCTest
@testable import Turnip

/// The archive keeps a video's pose until the app is deleted, so analyzing it again reads the
/// frames instead of scoring them. These pin what reuse depends on: the frames come back whole,
/// with the spacing and size they were scored at, only for the file they were scored from, and
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

    private let file = VideoPoseArchive.Fingerprint(duration: 10, frameHashes: [0x0F0F, 0xFF00, 0x00FF])

    private func pose(count: Int, interval: TimeInterval = 0.1) throws -> PartialPoseFrames {
        try PartialPoseFrames(
            frames: (0..<count).map { MultiPoseFrame(single: PoseFixture.body(index: $0, hip: (x: 0.5, y: 0.5))) },
            interval: interval, renderedPixelSize: CGSize(width: 48, height: 64))
    }

    func testAKeptPoseComesBackWithItsSpacingAndSize() throws {
        let archive = VideoPoseArchive(directory: directory)
        let kept = try pose(count: 5, interval: 0.1)
        // A real identifier's shape: slashes, which the entry's file name can't carry as they are.
        archive.keep(kept, for: "4E2B-91A0/L0/001", fingerprint: file)

        let read = try XCTUnwrap(archive.pose(for: "4E2B-91A0/L0/001", fingerprint: file))
        XCTAssertEqual(try read.store.loadAll().map(\.timestamp), try kept.store.loadAll().map(\.timestamp))
        XCTAssertEqual(read.interval, 0.1)
        XCTAssertEqual(read.renderedPixelSize, CGSize(width: 48, height: 64))
    }

    /// An edit saved in Photos keeps the identifier but not the file: a trim of a frame changes
    /// the length, a crop or a turn the pictures. Either passes the old pose over; a few bits of
    /// scaling difference in the pictures don't.
    func testAPoseIsOnlyForTheFileItWasScoredFrom() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 3), for: "video", fingerprint: file)

        let rescaled = VideoPoseArchive.Fingerprint(duration: 10, frameHashes: [0x0F0E, 0xFF01, 0x00FF])
        XCTAssertNotNil(archive.pose(for: "video", fingerprint: rescaled))
        let trimmed = VideoPoseArchive.Fingerprint(duration: 10 - 1.0 / 60, frameHashes: file.frameHashes)
        XCTAssertNil(archive.pose(for: "video", fingerprint: trimmed), "a video trimmed by a frame read its old pose")
        let turned = VideoPoseArchive.Fingerprint(duration: 10, frameHashes: [0xF0F0, 0x00FF, 0xFF00])
        XCTAssertNil(archive.pose(for: "video", fingerprint: turned), "a turned picture read its old pose")
        XCTAssertNil(archive.pose(for: "another video", fingerprint: file))
    }

    func testKeepingAgainReplacesTheEntry() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 3), for: "video", fingerprint: file)
        archive.keep(try pose(count: 6, interval: 0.2), for: "video", fingerprint: file)

        let read = try XCTUnwrap(archive.pose(for: "video", fingerprint: file))
        XCTAssertEqual(read.store.count, 6)
        XCTAssertEqual(read.interval, 0.2)
    }

    /// The pose handed out is in a store of its own: a run that discards it leaves the entry.
    func testTheEntryOutlivesTheStoreItHandsOut() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 3), for: "video", fingerprint: file)

        try XCTUnwrap(archive.pose(for: "video", fingerprint: file)).store.discard()
        XCTAssertEqual(archive.pose(for: "video", fingerprint: file)?.store.count, 3)
    }

    func testAPoseWithNoFramesIsNotKept() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 0), for: "video", fingerprint: file)

        XCTAssertNil(archive.pose(for: "video", fingerprint: file))
    }

    /// It can always be scored again from the video, so it stays out of device backups.
    func testTheArchiveIsLeftOutOfBackups() throws {
        let archive = VideoPoseArchive(directory: directory)
        archive.keep(try pose(count: 2), for: "video", fingerprint: file)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testNoDirectoryKeepsNothing() throws {
        let archive = VideoPoseArchive(directory: nil)
        archive.keep(try pose(count: 2), for: "video", fingerprint: file)

        XCTAssertNil(archive.pose(for: "video", fingerprint: file))
    }

    // MARK: - Fingerprint

    /// A grey picture, white on its left half and black on its right, or the other way round, at
    /// the hash's own 8 × 8, so no scaling blurs the edge between them.
    private func halves(whiteOnTheLeft: Bool) throws -> CGImage {
        let side = 8
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: whiteOnTheLeft ? 0 : side / 2, y: 0, width: side / 2, height: side))
        return try XCTUnwrap(context.makeImage())
    }

    /// The hash is the picture's bright and dark: the same picture gives the same bits, and the
    /// picture turned half round gives none of them.
    func testTheAverageHashTellsAPictureFromItsMirror() throws {
        let left = try XCTUnwrap(VideoPoseArchive.Fingerprint.averageHash(of: try halves(whiteOnTheLeft: true)))
        let again = try XCTUnwrap(VideoPoseArchive.Fingerprint.averageHash(of: try halves(whiteOnTheLeft: true)))
        let right = try XCTUnwrap(VideoPoseArchive.Fingerprint.averageHash(of: try halves(whiteOnTheLeft: false)))

        XCTAssertEqual(left, again)
        XCTAssertEqual(left.nonzeroBitCount, 32, "half the pixels are brighter than the mean")
        XCTAssertEqual(left ^ right, UInt64.max, "the mirror shares no bright pixel")
    }

    /// Read off a real file twice, the fingerprint is the same; off a file one frame longer, it
    /// doesn't match.
    func testAFilesFingerprintIsStableAndKnowsItsLength() async throws {
        let url = try await TestVideoWriter.writeTestVideo(frameCount: 30, width: 64, height: 48, fps: 30)
        let longer = try await TestVideoWriter.writeTestVideo(frameCount: 31, width: 64, height: 48, fps: 30)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: longer)
        }

        let first = await VideoPoseArchive.Fingerprint.of(AVURLAsset(url: url))
        let second = await VideoPoseArchive.Fingerprint.of(AVURLAsset(url: url))
        let other = await VideoPoseArchive.Fingerprint.of(AVURLAsset(url: longer))
        let read = try XCTUnwrap(first)

        XCTAssertEqual(read.frameHashes.count, 3)
        XCTAssertTrue(read.matches(try XCTUnwrap(second)))
        XCTAssertFalse(read.matches(try XCTUnwrap(other)), "a file a frame longer read as the same file")
    }
}
