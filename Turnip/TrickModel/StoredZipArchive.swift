import Foundation
import zlib

/// Unpacks the trick model's artifact: a zip of `TrickDetector.mlpackage` whose entries are
/// stored, not compressed, as turnip-ml's export writes it (`MODEL_CONTRACT.md` §2). iOS has no
/// public unzip API, and a stored archive needs none: each entry's bytes sit in the file as they
/// are. The bytes are a model the app will run, so anything this reader doesn't expect fails the
/// whole extraction rather than being skipped: a compressed or encrypted entry, ZIP64, a size or
/// checksum that doesn't add up, or a path that would land outside the destination.
enum StoredZipArchive {
    enum Failure: Error, Equatable {
        case malformed
        case unsupportedEntry(String)
        case unsafePath(String)
        case checksumMismatch(String)
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let endOfCentralDirectorySize = 22
    private static let centralDirectoryHeaderSize = 46
    private static let localHeaderSize = 30

    /// Writes every file entry of `archive` under `directory`, creating the folders its paths
    /// name; the export's zip lists files only, never their folders.
    static func extract(_ archive: Data, to directory: URL) throws {
        let bytes = [UInt8](archive)
        let end = try endOfCentralDirectory(in: bytes)
        let entryCount = Int(try read(UInt16.self, in: bytes, at: end + 10))
        let directoryOffset = Int(try read(UInt32.self, in: bytes, at: end + 16))
        guard entryCount != Int(UInt16.max), directoryOffset != Int(UInt32.max) else {
            throw Failure.unsupportedEntry("ZIP64")
        }
        var offset = directoryOffset
        for _ in 0..<entryCount {
            offset = try extractEntry(describedAt: offset, in: bytes, to: directory)
        }
    }

    /// The offset of the end-of-central-directory record, searched backwards from the end of the
    /// file past a trailing comment of any length.
    private static func endOfCentralDirectory(in bytes: [UInt8]) throws -> Int {
        var offset = bytes.count - endOfCentralDirectorySize
        let lowest = max(0, offset - Int(UInt16.max))
        while offset >= lowest {
            if try read(UInt32.self, in: bytes, at: offset) == endOfCentralDirectorySignature {
                return offset
            }
            offset -= 1
        }
        throw Failure.malformed
    }

    /// Extracts the entry whose central-directory header starts at `offset` and returns the
    /// offset of the next header.
    private static func extractEntry(describedAt offset: Int, in bytes: [UInt8], to directory: URL) throws -> Int {
        guard try read(UInt32.self, in: bytes, at: offset) == centralDirectorySignature else {
            throw Failure.malformed
        }
        let flags = try read(UInt16.self, in: bytes, at: offset + 8)
        let method = try read(UInt16.self, in: bytes, at: offset + 10)
        let crc = try read(UInt32.self, in: bytes, at: offset + 16)
        let compressedSize = Int(try read(UInt32.self, in: bytes, at: offset + 20))
        let size = Int(try read(UInt32.self, in: bytes, at: offset + 24))
        let nameLength = Int(try read(UInt16.self, in: bytes, at: offset + 28))
        let extraLength = Int(try read(UInt16.self, in: bytes, at: offset + 30))
        let commentLength = Int(try read(UInt16.self, in: bytes, at: offset + 32))
        let localOffset = Int(try read(UInt32.self, in: bytes, at: offset + 42))
        let nameStart = offset + centralDirectoryHeaderSize
        let name = try string(in: bytes, from: nameStart, count: nameLength)

        // Bit 0 is encryption. Method 0 is stored; anything else is compressed.
        guard flags & 1 == 0, method == 0, compressedSize == size else {
            throw Failure.unsupportedEntry(name)
        }
        let components = try safeComponents(of: name)
        let next = nameStart + nameLength + extraLength + commentLength
        guard !name.hasSuffix("/") else { return next }

        guard try read(UInt32.self, in: bytes, at: localOffset) == localHeaderSignature else {
            throw Failure.malformed
        }
        let localNameLength = Int(try read(UInt16.self, in: bytes, at: localOffset + 26))
        let localExtraLength = Int(try read(UInt16.self, in: bytes, at: localOffset + 28))
        let dataStart = localOffset + localHeaderSize + localNameLength + localExtraLength
        guard dataStart + size <= bytes.count else { throw Failure.malformed }
        let contents = bytes[dataStart..<(dataStart + size)]
        let computed = contents.withUnsafeBufferPointer {
            UInt32(zlib.crc32(0, $0.baseAddress, uInt($0.count)))
        }
        guard computed == crc else { throw Failure.checksumMismatch(name) }

        let destination = components.reduce(directory) { $0.appendingPathComponent($1) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents).write(to: destination)
        return next
    }

    /// The entry's path components, refusing any name that could resolve outside the destination:
    /// an absolute path, a `.` or `..` component, an empty component, or a backslash, which some
    /// unzippers read as a separator.
    private static func safeComponents(of name: String) throws -> [String] {
        let path = name.hasSuffix("/") ? String(name.dropLast()) : name
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let safe = !path.isEmpty && !path.contains("\\")
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard safe else { throw Failure.unsafePath(name) }
        return components
    }

    private static func string(in bytes: [UInt8], from start: Int, count: Int) throws -> String {
        guard start >= 0, start + count <= bytes.count,
              let name = String(bytes: bytes[start..<(start + count)], encoding: .utf8)
        else { throw Failure.malformed }
        return name
    }

    private static func read<Value: FixedWidthInteger>(
        _: Value.Type, in bytes: [UInt8], at offset: Int
    ) throws -> Value {
        let size = MemoryLayout<Value>.size
        guard offset >= 0, offset + size <= bytes.count else { throw Failure.malformed }
        return (0..<size).reduce(Value.zero) { $0 | Value(bytes[offset + $1]) << ($1 * 8) }
    }
}
