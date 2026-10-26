import Foundation
import zlib

/// One source's pose as contribution sends it (`POSE_FORMAT.md`, the farm's wire format): the
/// analysis's own detections on a uniform grid at the rate they were sampled, one slot per
/// sample, and a gap wherever no keypoint cleared the detector's confidence floor or no sample
/// landed. Raw, never reconstructed: the farm resamples to its canonical 10 Hz on ingest and
/// refuses to interpolate across gaps, so nothing here fills one in
/// (`docs/CONTRIBUTION_DESIGN.md` §2.2).
struct ContributionPose: Equatable, Sendable {
    /// Samples per second of the grid, as float32 because that is what the blob's header and
    /// the farm's frame-count arithmetic carry.
    let sampleRate: Float
    /// Per grid slot, x/y/confidence for the 17 COCO keypoints, or `nil` for a gap.
    let slots: [[Float]?]

    static let canonicalRate: Float = 10
    static let keypointCount = 17

    /// Lays `frames` on a grid anchored at the video's start: slot `j` sits at `j / rate`, the
    /// rate read off the frames' own spacing (the median step, so a dropped sample doesn't skew
    /// it), and the grid runs to `duration`. A frame lands in the slot nearest its timestamp; a
    /// second frame for a slot already taken is dropped rather than averaged in. `nil` without at
    /// least two frames to read a rate from.
    init?(frames: [PoseFrameResult], duration: TimeInterval) {
        let sorted = frames.sorted { $0.timestamp < $1.timestamp }
        let steps = zip(sorted, sorted.dropFirst()).map { $1.timestamp - $0.timestamp }.filter { $0 > 0 }.sorted()
        guard !steps.isEmpty else { return nil }
        let measured = 1 / steps[steps.count / 2]
        let rate = Float(min(max((measured * 1000).rounded() / 1000, 1), 30))
        let lastSlot = Int((Double(rate) * max(duration, sorted.last?.timestamp ?? 0)).rounded(.down))
        var slots = [[Float]?](repeating: nil, count: lastSlot + 1)
        for frame in sorted {
            let slot = Int((frame.timestamp * Double(rate)).rounded())
            guard slots.indices.contains(slot), slots[slot] == nil else { continue }
            slots[slot] = Self.values(of: frame)
        }
        self.init(sampleRate: rate, slots: slots)
    }

    init(sampleRate: Float, slots: [[Float]?]) {
        self.sampleRate = sampleRate
        self.slots = slots
    }

    /// x, y, confidence per keypoint as the model emitted them, unclamped; `nil` for a frame
    /// with no usable keypoint, which the blob writes as a gap.
    private static func values(of frame: PoseFrameResult) -> [Float]? {
        guard frame.keypoints.count == keypointCount, frame.usableKeypointCount > 0 else { return nil }
        return frame.keypoints.flatMap { [$0.x, $0.y, $0.confidence] }
    }

    /// The farm's canonical frame count for this grid (`POSE_FORMAT.md` §6), computed exactly
    /// as its ingest does — float32 rate, double arithmetic, a 10 Hz grid passed through — so
    /// the count registered and the count ingested agree to the frame.
    var canonicalFrameCount: Int {
        let count = slots.count
        let rate = Double(sampleRate)
        guard rate != Double(Self.canonicalRate) else { return count }
        return Int((Double(count - 1) / rate * Double(Self.canonicalRate)).rounded(.down)) + 1
    }

    /// A clip window in canonical frames, end exclusive, inside `0..<canonicalFrameCount`:
    /// the frames the farm validates and trains on.
    func canonicalFrames(of window: TrickWindow) -> (start: Int, end: Int) {
        let count = canonicalFrameCount
        let rate = Double(Self.canonicalRate)
        let start = min(max(Int((window.startTime * rate).rounded(.down)), 0), max(count - 1, 0))
        let end = min(max(Int((window.endTime * rate).rounded(.up)), start + 1), count)
        return (start, end)
    }

    /// The share of grid slots inside `windows` that are gaps — what decides whether the clips
    /// are worth contributing (`docs/CONTRIBUTION_DESIGN.md` §2.3). 1 when no slot falls inside.
    func gapFraction(in windows: [TrickWindow]) -> Double {
        let rate = Double(sampleRate)
        var inside = 0, gaps = 0
        for (index, slot) in slots.enumerated() {
            let time = Double(index) / rate
            guard windows.contains(where: { $0.startTime <= time && time <= $0.endTime }) else { continue }
            inside += 1
            if slot == nil { gaps += 1 }
        }
        return inside == 0 ? 1 : Double(gaps) / Double(inside)
    }

    /// The uncompressed blob: the 24-byte header (`sample_rate_hz` the canonical 10, the grid's
    /// own rate as `source_sample_rate_hz`), then every slot's 17 × (x, y, confidence) float32
    /// little-endian, gaps as 204 zero bytes.
    var tkp1: Data {
        var data = Data(capacity: 24 + slots.count * Self.keypointCount * 12)
        data.append(contentsOf: Array("TKP1".utf8))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(Self.keypointCount))
        data.appendLittleEndian(UInt32(slots.count))
        data.appendLittleEndian(Self.canonicalRate.bitPattern)
        data.appendLittleEndian(sampleRate.bitPattern)
        data.appendLittleEndian(UInt32(0))
        let gap = [Float](repeating: 0, count: Self.keypointCount * 3)
        for slot in slots {
            for value in slot ?? gap {
                data.appendLittleEndian(value.bitPattern)
            }
        }
        return data
    }

    /// The blob as uploaded: the whole of `tkp1` as one gzip member.
    var gzippedTKP1: Data? { Self.gzip(tkp1) }

    static func gzip(_ input: Data) -> Data? {
        var stream = z_stream()
        // 15 window bits plus 16 asks zlib for a gzip wrapper (header and CRC) instead of zlib's.
        guard deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(input.count))))
        let status = input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int32 in
            output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int32 in
                stream.next_in = source.bindMemory(to: Bytef.self).baseAddress.map(UnsafeMutablePointer.init(mutating:))
                stream.avail_in = uInt(input.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(target.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        return output.prefix(Int(stream.total_out))
    }
}

private extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
