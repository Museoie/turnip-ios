import Foundation
import os

/// A disk-backed, append-only store for packed pose frames, written as the live drain scores
/// them and read back when the take is detected or backfilled. A recording session scores a
/// frame every 100 ms for as long as it runs, so keeping every rich frame in memory grows
/// without bound (~1.8 KB per frame with one person, ~65 MB/hour at 10 samples/s). The store
/// keeps at most one 64 KB write buffer in memory; the frames live in a temp file until a
/// consumer loads them.
///
/// Lifecycle: appends happen only while the drain runs; reads happen only after the drain has
/// finished and flushed. `discard()` deletes the file on the paths the owner controls; `deinit`
/// deletes it as a safety net, so an abandoned recording leaves nothing behind either.
///
/// The file is device-local scratch, not a portable format: values are little-endian, and the
/// file is never read by another process or version. Format: 8-byte header (magic "TPOS",
/// version 1), then records: frameIndex Int64, timestamp Double bits, person count UInt32,
/// then per person score Float, box 4× Float, keypoint count UInt32, keypoints 3× Float each.
final class PoseFrameStore: Hashable, Sendable {
    static func == (lhs: PoseFrameStore, rhs: PoseFrameStore) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    /// Filename prefix for the scratch files. A bare UUID would be indistinguishable from
    /// every other temp file; the prefix lets the launch sweep recognize files this store
    /// created — and only those.
    static let temporaryFilenamePrefix = "turnip-live-pose-"

    /// The scratch file. Unique per store; under the temporary directory so the system may
    /// purge it if the app is killed before cleanup runs.
    let fileURL: URL

    /// Bytes buffered in memory, awaiting flush. Never more than the flush threshold — this is
    /// the bound the drain relies on, and the property the tests assert.
    var bufferedByteCount: Int {
        state.withLock { $0.buffer.count }
    }

    var count: Int {
        state.withLock { $0.count }
    }

    var isEmpty: Bool { count == 0 }

    private struct State: Sendable {
        var buffer = Data()
        var count = 0
        var fileExists = false
        var discarded = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let flushThreshold = 64 * 1024

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.temporaryFilenamePrefix)\(UUID().uuidString).bin")
    }

    /// A store prefilled with frames — for tests and for `PartialPoseFrames(frames:)` — the
    /// same bytes the drain would have written for them.
    convenience init(frames: [MultiPoseFrame]) throws {
        self.init()
        for frame in frames {
            try append(frame)
        }
        try flush()
    }

    /// Packs one frame and buffers it, flushing to the file at 64 KB. A failure surfaces to
    /// the drain, which reports it the same way it reports an inference failure.
    func append(_ frame: MultiPoseFrame) throws {
        try state.withLock { state in
            guard !state.discarded else { throw PoseFrameStoreError.discarded }
            if state.count == 0 && state.buffer.isEmpty {
                appendFileHeader(to: &state.buffer)
            }
            RecordCoder.encode(PackedPoseFrame(frame), into: &state.buffer)
            state.count += 1
            if state.buffer.count >= Self.flushThreshold {
                try flushLocked(&state)
            }
        }
    }

    /// Writes the buffered bytes to the file. Called automatically at 64 KB and by the drain
    /// before it hands the outcome over — a store that was never flushed is missing its tail.
    func flush() throws {
        try state.withLock { state in try flushLocked(&state) }
    }

    /// The stored frames in timestamp order, unpacked. Loads the whole file: call once and
    /// keep the array — the file is read again on every call. Throws when the file cannot be
    /// read; an empty store (nothing ever appended) returns `[]` without touching the disk.
    func loadAll() throws -> [MultiPoseFrame] {
        guard state.withLock({ $0.fileExists }) else { return [] }
        let reader = try RecordReader(url: fileURL)
        var frames: [MultiPoseFrame] = []
        frames.reserveCapacity(count)
        while let packed = try reader.next() {
            frames.append(packed.unpack())
        }
        return frames
    }

    /// The stored frames in timestamp order, unpacked one record at a time as the sequence is
    /// consumed — the file is never read whole. A fresh file handle is opened per iteration, so
    /// the sequence can be iterated more than once. A record that fails to parse ends the
    /// sequence: the file is only ever written by this store, so a short read means the file
    /// was truncated. Consume on the task that created the sequence.
    func frames() -> AnySequence<MultiPoseFrame> {
        AnySequence { FrameIterator(store: self) }
    }

    /// Deletes the file. Idempotent; safe to call after the frames were loaded.
    func discard() {
        state.withLock { state in
            guard !state.discarded else { return }
            state.discarded = true
            state.buffer.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    deinit {
        if !state.withLock({ $0.discarded }) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func flushLocked(_ state: inout State) throws {
        guard !state.buffer.isEmpty else { return }
        if !state.fileExists {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            state.fileExists = true
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: state.buffer)
        state.buffer.removeAll(keepingCapacity: true)
    }

    private func appendFileHeader(to data: inout Data) {
        appendUInt32(RecordCoder.magic, to: &data)
        appendUInt32(RecordCoder.version, to: &data)
    }
}

enum PoseFrameStoreError: Error {
    /// An append or read after the store was discarded.
    case discarded
    /// A short or implausible record in the file.
    case corrupt
}

/// The on-disk record format. Encoding appends little-endian values; decoding reads exact
/// byte counts and rejects short reads and implausible counts.
private enum RecordCoder {
    static let magic: UInt32 = 0x5450_4F53 // "TPOS"
    static let version: UInt32 = 1
    static let headerByteCount = 8
    static let recordHeaderByteCount = 20
    static let personHeaderByteCount = 24
    /// Sanity bound for a record: production frames carry 17 joints; anything above this is a
    /// corrupt file, not a frame.
    static let maxKeypointsPerPerson = 64

    static func encode(_ frame: PackedPoseFrame, into data: inout Data) {
        appendInt64(Int64(frame.frameIndex), to: &data)
        appendUInt64(frame.timestamp.bitPattern, to: &data)
        appendUInt32(UInt32(frame.people.count), to: &data)
        for person in frame.people {
            appendFloat(person.score, to: &data)
            appendFloat(person.box.minX, to: &data)
            appendFloat(person.box.maxX, to: &data)
            appendFloat(person.box.minY, to: &data)
            appendFloat(person.box.maxY, to: &data)
            appendUInt32(UInt32(person.keypoints.count / 3), to: &data)
            for value in person.keypoints {
                appendFloat(value, to: &data)
            }
        }
    }
}

/// Reads one record at a time from the store file. `next()` returns nil at a clean end and
/// throws on a short or implausible record.
private final class RecordReader {
    private let handle: FileHandle
    private var checkedHeader = false

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    func next() throws -> PackedPoseFrame? {
        if !checkedHeader {
            checkedHeader = true
            let header = try readExactly(RecordCoder.headerByteCount)
            guard !header.isEmpty else { return nil }
            guard header.count == RecordCoder.headerByteCount,
                  header.uint32(at: 0) == RecordCoder.magic,
                  header.uint32(at: 4) == RecordCoder.version else {
                throw PoseFrameStoreError.corrupt
            }
        }
        let recordHeader = try readExactly(RecordCoder.recordHeaderByteCount)
        guard !recordHeader.isEmpty else { return nil }
        guard recordHeader.count == RecordCoder.recordHeaderByteCount,
              let personCount = recordHeader.uint32(at: 16),
              personCount <= UInt32(DetectedPerson.maximumCount) else {
            throw PoseFrameStoreError.corrupt
        }
        guard let frameIndex = recordHeader.int64(at: 0),
              let timestampBits = recordHeader.uint64(at: 8) else {
            throw PoseFrameStoreError.corrupt
        }
        var people: [PackedPosePerson] = []
        people.reserveCapacity(Int(personCount))
        for _ in 0..<personCount {
            people.append(try nextPerson())
        }
        return PackedPoseFrame(
            frameIndex: Int(frameIndex),
            timestamp: Double(bitPattern: timestampBits),
            people: people)
    }

    /// One person: score, box, keypoint count, then the keypoint floats.
    private func nextPerson() throws -> PackedPosePerson {
        let personHeader = try readExactly(RecordCoder.personHeaderByteCount)
        guard personHeader.count == RecordCoder.personHeaderByteCount,
              let score = personHeader.float(at: 0),
              let minX = personHeader.float(at: 4),
              let maxX = personHeader.float(at: 8),
              let minY = personHeader.float(at: 12),
              let maxY = personHeader.float(at: 16),
              let keypointCount = personHeader.uint32(at: 20),
              keypointCount <= UInt32(RecordCoder.maxKeypointsPerPerson) else {
            throw PoseFrameStoreError.corrupt
        }
        let keypointByteCount = Int(keypointCount) * 3 * MemoryLayout<Float>.size
        let keypointBytes = try readExactly(keypointByteCount)
        guard keypointBytes.count == keypointByteCount else {
            throw PoseFrameStoreError.corrupt
        }
        var keypoints: [Float] = []
        keypoints.reserveCapacity(Int(keypointCount) * 3)
        for offset in stride(from: 0, to: keypointBytes.count, by: MemoryLayout<Float>.size) {
            guard let value = keypointBytes.float(at: offset) else {
                throw PoseFrameStoreError.corrupt
            }
            keypoints.append(value)
        }
        return PackedPosePerson(
            score: score,
            box: NormalizedRect(minX: minX, maxX: maxX, minY: minY, maxY: maxY),
            keypoints: keypoints)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }
}

/// The lazy sequence's iterator: opens its own file handle, so each iteration reads the file
/// from the start. A parse failure ends the sequence.
private struct FrameIterator: IteratorProtocol {
    private var reader: RecordReader?

    init(store: PoseFrameStore) {
        reader = try? RecordReader(url: store.fileURL)
    }

    mutating func next() -> MultiPoseFrame? {
        guard let reader else { return nil }
        do {
            return try reader.next()?.unpack()
        } catch {
            return nil
        }
    }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}

private func appendUInt64(_ value: UInt64, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}

private func appendInt64(_ value: Int64, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}

private func appendFloat(_ value: Float, to data: inout Data) {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32? {
        guard offset + MemoryLayout<UInt32>.size <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    func uint64(at offset: Int) -> UInt64? {
        guard offset + MemoryLayout<UInt64>.size <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.littleEndian
    }

    func int64(at offset: Int) -> Int64? {
        guard offset + MemoryLayout<Int64>.size <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int64.self) }.littleEndian
    }

    func float(at offset: Int) -> Float? {
        guard offset + MemoryLayout<Float>.size <= count else { return nil }
        return Float(bitPattern: withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }.littleEndian)
    }
}
