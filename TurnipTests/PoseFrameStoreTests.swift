import Foundation
import XCTest
@testable import Turnip

/// The store is the disk half of the fix: frames are packed and appended as they are scored,
/// and read back only when the take is detected or backfilled. These tests pin the three
/// properties the drain relies on — the file holds every frame, memory stays bounded, and
/// nothing is left behind.
final class PoseFrameStoreTests: XCTestCase {
    func testAppendLoadAllRoundTripsValues() throws {
        let store = PoseFrameStore()
        let frames = (0..<5).map { index in
            MultiPoseFrame(single: PoseFixture.body(index: index, hip: (x: 0.4 + Float(index) * 0.02, y: 0.5)))
        }
        for frame in frames {
            try store.append(frame)
        }
        try store.flush()

        XCTAssertEqual(store.count, 5)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.frameIndex), frames.map(\.frameIndex))
        XCTAssertEqual(loaded.map(\.timestamp), frames.map(\.timestamp))
        for (got, want) in zip(loaded, frames) {
            XCTAssertEqual(
                got.primary.keypoints.map { [$0.y, $0.x, $0.confidence] },
                want.primary.keypoints.map { [$0.y, $0.x, $0.confidence] })
        }
    }

    func testRoundTripsMultiplePeopleAndEmptyFrames() throws {
        let store = PoseFrameStore()
        let people = (0..<6).map { index in
            DetectedPerson.fixture(
                [PoseKeypoint(name: "nose", y: 0.1 * Float(index), x: 0.2, confidence: 0.9)],
                score: 0.9 - Float(index) * 0.1)
        }
        try store.append(MultiPoseFrame(frameIndex: 7, timestamp: 0.7, people: people))
        try store.append(MultiPoseFrame(frameIndex: 8, timestamp: 0.8, people: []))
        try store.flush()

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].people.count, 6)
        XCTAssertEqual(loaded[0].people.map(\.score), people.map(\.score))
        XCTAssertEqual(loaded[1].people.count, 0)
        XCTAssertEqual(loaded[1].frameIndex, 8)
    }

    func testFramesSequenceIsRepeatable() throws {
        let frames = (0..<3).map { index in
            MultiPoseFrame(single: PoseFixture.body(index: index, hip: (x: 0.5, y: 0.5)))
        }
        let store = try PoseFrameStore(frames: frames)

        let first = Array(store.frames())
        let second = Array(store.frames())

        XCTAssertEqual(first.map(\.frameIndex), frames.map(\.frameIndex))
        XCTAssertEqual(second.map(\.frameIndex), first.map(\.frameIndex), "a second pass re-reads the file")
    }

    func testFramesSequenceReadsOnIterationNotOnCreation() throws {
        let frames = (0..<3).map { index in
            MultiPoseFrame(single: PoseFixture.body(index: index, hip: (x: 0.5, y: 0.5)))
        }
        let store = try PoseFrameStore(frames: frames)
        let sequence = store.frames()
        store.discard()

        XCTAssertTrue(Array(sequence).isEmpty, "nothing was read before iteration started")
    }

    func testStoreHoldsOnlyABufferInMemory() throws {
        let store = PoseFrameStore()
        for index in 0..<1_000 {
            try store.append(MultiPoseFrame(single: PoseFixture.body(index: index, hip: (x: 0.5, y: 0.5))))
        }

        XCTAssertEqual(store.count, 1_000)
        XCTAssertLessThan(store.bufferedByteCount, 64 * 1024, "the buffer flushes at the threshold")
        try store.flush()
        XCTAssertEqual(try store.loadAll().count, 1_000, "flushing early loses nothing")
    }

    func testFlushWritesTheTail() throws {
        let store = PoseFrameStore()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL.path), "no file before the first append")
        try store.append(MultiPoseFrame(single: PoseFixture.body(index: 0, hip: (x: 0.5, y: 0.5))))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL.path), "one frame stays buffered")
        try store.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try store.loadAll().count, 1)
    }

    func testEmptyStoreLoadsNothingAndCreatesNoFile() throws {
        let store = PoseFrameStore()
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(try store.loadAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testPackedFileIsSmall() throws {
        // 100 one-person frames: ~25 KB packed against ~180 KB for the rich frames they
        // replace. A regression that stored the names or ids would show up here.
        let store = PoseFrameStore()
        for index in 0..<100 {
            try store.append(MultiPoseFrame(single: PoseFixture.body(index: index, hip: (x: 0.5, y: 0.5))))
        }
        try store.flush()

        let size = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 100 * 300)
    }

    func testDiscardDeletesTheFileAndIsIdempotent() throws {
        let store = PoseFrameStore()
        try store.append(MultiPoseFrame(single: PoseFixture.body(index: 0, hip: (x: 0.5, y: 0.5))))
        try store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        store.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        store.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testDeinitDeletesTheFile() throws {
        var store: PoseFrameStore? = PoseFrameStore()
        try store?.append(MultiPoseFrame(single: PoseFixture.body(index: 0, hip: (x: 0.5, y: 0.5))))
        try store?.flush()
        let url = try XCTUnwrap(store?.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store = nil
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path), "an abandoned recording leaves nothing behind")
    }

    func testConvenienceInitWritesFrames() throws {
        let frames = (0..<3).map { index in
            MultiPoseFrame(single: PoseFixture.body(index: index, hip: (x: 0.5, y: 0.5)))
        }
        let store = try PoseFrameStore(frames: frames)

        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(try store.loadAll().map(\.frameIndex), frames.map(\.frameIndex))
    }
}
