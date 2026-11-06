import XCTest
@testable import Turnip

/// Reading a TKP1 blob back: the rebuild runs the trick model over what these return, so a pose
/// that comes back different would feed the model something it never saw at analysis.
final class PoseDecodingTests: XCTestCase {
    private func slot(_ value: Float) -> [Float] {
        (0..<51).map { value + Float($0) / 100 }
    }

    /// `POSE_FORMAT.md` §11.1's shape, at a rate that isn't canonical: the grid's own rate has to
    /// come back, not the canonical one the header also carries.
    private var pose: ContributionPose {
        ContributionPose(sampleRate: 12.5, slots: [slot(0.1), nil, slot(0.3), nil, nil, slot(0.6)])
    }

    private func tampered(_ change: (inout [UInt8]) -> Void) -> Data {
        var bytes = [UInt8](pose.tkp1)
        change(&bytes)
        return Data(bytes)
    }

    func testReadsBackWhatItWroteSlotForSlot() {
        XCTAssertEqual(ContributionPose(tkp1: pose.tkp1), pose)
    }

    func testReadsBackTheGzippedBlob() throws {
        XCTAssertEqual(ContributionPose(gzippedTKP1: try XCTUnwrap(pose.gzippedTKP1)), pose)
    }

    func testReadsAPoseLargerThanOneInflateChunk() throws {
        let long = ContributionPose(sampleRate: 30, slots: (0..<2_000).map { slot(Float($0 % 97) + 1) })
        XCTAssertEqual(ContributionPose(gzippedTKP1: try XCTUnwrap(long.gzippedTKP1)), long)
    }

    /// A sample with some keypoints at zero is a sample; only a slot of nothing but zeros is a gap.
    func testASampleWithZeroKeypointsIsNotAGap() {
        var values = [Float](repeating: 0, count: 51)
        values[2] = 0.9
        let pose = ContributionPose(sampleRate: 10, slots: [values, nil])
        XCTAssertEqual(ContributionPose(tkp1: pose.tkp1)?.slots, [values, nil])
    }

    /// What the trick model reads from a stored pose has to be what it read at analysis.
    func testAStoredPoseGivesTheModelTheInputTheFramesGave() throws {
        let frames = PoseFixture.frames(hipXPositions: (0..<40).map { Float($0) / 40 }, blankFrames: [7, 8, 21])
        let pose = try XCTUnwrap(ContributionPose(frames: frames, duration: 5))
        let stored = try XCTUnwrap(ContributionPose(gzippedTKP1: try XCTUnwrap(pose.gzippedTKP1)))
        XCTAssertEqual(TrickModelInput(pose: stored), TrickModelInput(frames: frames, duration: 5))
    }

    func testRefusesAnythingButAWholeBlob() {
        XCTAssertNil(ContributionPose(tkp1: Data()), "empty")
        XCTAssertNil(ContributionPose(tkp1: pose.tkp1.prefix(23)), "a header cut short")
        XCTAssertNil(ContributionPose(tkp1: pose.tkp1.dropLast()), "a slot cut short")
        XCTAssertNil(ContributionPose(tkp1: pose.tkp1 + [0]), "a byte past the end")
        XCTAssertNil(ContributionPose(tkp1: tampered { $0[0] = 0 }), "the magic")
        XCTAssertNil(ContributionPose(tkp1: tampered { $0[4] = 2 }), "the version")
        XCTAssertNil(ContributionPose(tkp1: tampered { $0[6] = 16 }), "the keypoint count")
        XCTAssertNil(ContributionPose(tkp1: tampered { $0[8] = 5 }), "the slot count")
    }

    /// Slots are read as the grid's rate divides them, and `canonicalFrameCount` can't run on an
    /// empty grid or a rate that isn't one.
    func testRefusesAGridTheCanonicalArithmeticCantRun() {
        let empty = Data(pose.tkp1.prefix(24))
        XCTAssertNil(ContributionPose(tkp1: empty.replacingBytes(at: 8, with: [0, 0, 0, 0])), "no slots")
        let zeroRate = pose.tkp1.replacingBytes(at: 16, with: [0, 0, 0, 0])
        XCTAssertNil(ContributionPose(tkp1: zeroRate), "a rate of zero")
        let notARate = pose.tkp1.replacingBytes(at: 16, with: [0, 0, 0xC0, 0x7F])
        XCTAssertNil(ContributionPose(tkp1: notARate), "a rate that is not a number")
    }

    func testRefusesAGzipMemberCutShortOrDamaged() throws {
        let gzipped = try XCTUnwrap(pose.gzippedTKP1)
        XCTAssertNil(ContributionPose(gzippedTKP1: gzipped.dropLast(9)), "cut short")
        XCTAssertNil(ContributionPose(gzippedTKP1: Data()), "empty")
        var damaged = [UInt8](gzipped)
        damaged[damaged.count - 6] ^= 0xFF
        XCTAssertNil(ContributionPose(gzippedTKP1: Data(damaged)), "a failed CRC")
    }
}

private extension Data {
    func replacingBytes(at offset: Int, with bytes: [UInt8]) -> Data {
        var copy = [UInt8](self)
        copy.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        return Data(copy)
    }
}

final class SourcePoseStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SourcePoseStore { SourcePoseStore(directory: directory) }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-poses-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func pose(_ value: Float) -> ContributionPose {
        ContributionPose(sampleRate: 10, slots: [Array(repeating: value, count: 51), nil])
    }

    private var fileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    func testAStoredPoseIsReadBackByItsID() throws {
        let id = try XCTUnwrap(store.store(pose(0.2)))
        XCTAssertEqual(store.pose(id), pose(0.2))
    }

    /// The same pose saved again, as a second clip of one person is, shares the one file.
    func testTheSamePoseIsKeptOnce() {
        XCTAssertEqual(store.store(pose(0.2)), store.store(pose(0.2)))
        XCTAssertEqual(fileCount, 1)
    }

    /// A second analysis of a video, whose person 0 may be someone else, can't touch the pose the
    /// first analysis's clips name.
    func testADifferentPoseGetsItsOwnFile() throws {
        let first = try XCTUnwrap(store.store(pose(0.2)))
        let second = try XCTUnwrap(store.store(pose(0.7)))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.pose(first), pose(0.2))
        XCTAssertEqual(store.pose(second), pose(0.7))
    }

    func testRemovingAPoseDeletesItsFile() throws {
        let id = try XCTUnwrap(store.store(pose(0.2)))
        store.remove(id)
        XCTAssertNil(store.pose(id))
        XCTAssertEqual(fileCount, 0)
    }

    func testRemovingAPoseThatIsntThereDoesNothing() {
        store.remove("missing")
        XCTAssertEqual(fileCount, 0)
    }

    func testAMissingPoseReadsAsNone() {
        XCTAssertNil(store.pose("missing"))
    }

    func testAnUnreadableFileReadsAsNone() throws {
        let id = try XCTUnwrap(store.store(pose(0.2)))
        try Data("not a pose".utf8).write(to: directory.appendingPathComponent("\(id).tkp1.gz"))
        XCTAssertNil(store.pose(id))
    }

    func testNoDirectoryKeepsNothing() {
        let nowhere = SourcePoseStore(directory: nil)
        XCTAssertNil(nowhere.store(pose(0.2)))
        XCTAssertNil(nowhere.pose("any"))
        nowhere.remove("any")
    }

    /// A write that can't happen says so rather than handing clips an ID with no file behind it.
    func testAFailedWriteReturnsNoID() throws {
        try Data().write(to: directory)
        XCTAssertNil(store.store(pose(0.2)))
    }

    func testTheStoreSitsBesideTheLibraryFile() {
        let file = URL(fileURLWithPath: "/tmp/ClipLibrary/library.json")
        XCTAssertEqual(SourcePoseStore(besideLibraryFile: file).directory?.path, "/tmp/ClipLibrary/poses")
        XCTAssertNil(SourcePoseStore(besideLibraryFile: nil).directory)
    }
}
