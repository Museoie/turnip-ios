import CryptoKit
import XCTest
import zlib
@testable import Turnip

final class ContributionPoseTests: XCTestCase {
    /// `POSE_FORMAT.md` §11.1: three frames at 10 Hz, the middle one a gap. A conformant encoder
    /// produces these exact bytes, checked by the spec's digest.
    func testEncodesTheFormatSpecWorkedExampleByteForByte() {
        func frame(nose: [Float], shoulder: [Float]) -> [Float] {
            var values = [Float](repeating: 0, count: 51)
            values.replaceSubrange(0..<3, with: nose)
            values.replaceSubrange(15..<18, with: shoulder)
            return values
        }
        let pose = ContributionPose(sampleRate: 10, slots: [
            frame(nose: [0.5, 0.2, 0.95], shoulder: [0.45, 0.35, 0.9]),
            nil,
            frame(nose: [0.51, 0.21, 0.94], shoulder: [0.46, 0.36, 0.89])
        ])

        let blob = pose.tkp1
        XCTAssertEqual(blob.count, 636)
        XCTAssertEqual(
            VideoIdentity.sha256Hex(blob), "37ba29d3c206f3b9dd41219e29354c480791d000533efdfc8096ee6f0959cac9")
    }

    /// The upload is the same bytes in one gzip member, which the farm gunzips before decoding.
    func testGzipRoundTripsToTheUncompressedBlob() throws {
        let pose = ContributionPose(sampleRate: 12, slots: [Array(repeating: 0.25, count: 51), nil, nil])
        let gzipped = try XCTUnwrap(pose.gzippedTKP1)
        XCTAssertEqual(Array(gzipped.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(try Self.gunzip(gzipped), pose.tkp1)
    }

    /// `POSE_FORMAT.md` §11.3: five frames at 24 Hz are two canonical frames; a 10 Hz grid passes
    /// through unchanged, as the farm's ingest does.
    func testCanonicalFrameCountMatchesTheFarmsResampling() {
        func count(rate: Float, slots: Int) -> Int {
            ContributionPose(sampleRate: rate, slots: Array(repeating: nil, count: slots)).canonicalFrameCount
        }
        XCTAssertEqual(count(rate: 24, slots: 5), 2)
        XCTAssertEqual(count(rate: 10, slots: 37), 37)
        XCTAssertEqual(count(rate: 30, slots: 301), 101)
    }

    /// Frames land on the grid by their timestamps, anchored at the video's start and running to
    /// its end; a frame with nothing over the confidence floor is written as a gap, and so is a
    /// slot no frame reached.
    func testLaysFramesOnAGridAtTheirOwnRate() throws {
        let frames = [
            Self.frame(index: 0, at: 0.2, confidence: 0.9),
            Self.frame(index: 1, at: 0.3, confidence: 0.1),
            Self.frame(index: 2, at: 0.5, confidence: 0.8),
            Self.frame(index: 3, at: 0.6, confidence: 0.8)
        ]
        let pose = try XCTUnwrap(ContributionPose(frames: frames, duration: 1))

        XCTAssertEqual(pose.sampleRate, 10)
        XCTAssertEqual(pose.slots.count, 11)
        XCTAssertEqual(pose.slots.map { $0 != nil }, [
            false, false, true, false, false, true, true, false, false, false, false
        ])
        XCTAssertEqual(pose.slots[2]?.prefix(3), [0.5, 0.4, 0.9])
    }

    func testNeedsTwoFramesToReadARate() {
        XCTAssertNil(ContributionPose(frames: [Self.frame(index: 0, at: 0, confidence: 1)], duration: 3))
    }

    func testWindowsMapToCanonicalFramesInsideTheSequence() {
        let pose = ContributionPose(sampleRate: 10, slots: Array(repeating: nil, count: 51))
        XCTAssertEqual(pose.canonicalFrames(of: TrickWindow(startTime: 1.23, endTime: 2.71)).start, 12)
        XCTAssertEqual(pose.canonicalFrames(of: TrickWindow(startTime: 1.23, endTime: 2.71)).end, 28)
        // A window whose trailing buffer runs past the video ends at the last frame.
        XCTAssertEqual(pose.canonicalFrames(of: TrickWindow(startTime: 4, endTime: 8)).end, 51)
    }

    func testGapFractionCountsOnlySlotsInsideTheWindows() {
        let pose = ContributionPose(sampleRate: 10, slots: [nil, nil, [], [], nil, [], nil, nil])
        XCTAssertEqual(pose.gapFraction(in: [TrickWindow(startTime: 0.2, endTime: 0.5)]), 0.25)
        XCTAssertEqual(pose.gapFraction(in: [TrickWindow(startTime: 5, endTime: 6)]), 1)
    }

    func testVideoIDIsTheHashOfThePrefixedLocalIdentifier() {
        XCTAssertEqual(
            VideoIdentity.videoID(forAssetIdentifier: "ABC-123/L0/001"),
            "ad789354310f9efc8555c51106ebb628ee997a15d64447e64679b2f781d7f4f2")
    }

    private static func frame(index: Int, at time: TimeInterval, confidence: Float) -> PoseFrameResult {
        PoseFrameResult(
            frameIndex: index, timestamp: time,
            keypoints: PoseKeypoint.names.map { PoseKeypoint(name: $0, y: 0.4, x: 0.5, confidence: confidence) })
    }

    private static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&stream) }
        var output = Data(count: 1 << 20)
        let status = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                stream.next_in = source.bindMemory(to: Bytef.self).baseAddress.map(UnsafeMutablePointer.init(mutating:))
                stream.avail_in = uInt(data.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(target.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        return output.prefix(Int(stream.total_out))
    }
}
