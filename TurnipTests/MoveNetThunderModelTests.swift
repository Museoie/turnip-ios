import XCTest
@testable import Turnip

/// Covers the BGRA→RGB byte reorder `MoveNetThunderModel` applies before inference. Channel order
/// and row stride both fail silently — wrong bytes read as "the model is bad on this footage",
/// never as an error — so these tests pin them directly against the static seam.
final class MoveNetThunderModelTests: XCTestCase {

    // MARK: - Channel order

    func testRGBReorderWritesRedThenGreenThenBlue() {
        let width = 2
        let height = 2
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            storage[pixel * 4] = 10     // B
            storage[pixel * 4 + 1] = 20 // G
            storage[pixel * 4 + 2] = 30 // R
            storage[pixel * 4 + 3] = 255 // A
        }

        let rgb = withBGRABytes(storage) { bgra in
            MoveNetThunderModel.rgb(from: bgra, rowBytes: width * 4, width: width, height: height)
        }

        XCTAssertEqual(rgb.count, width * height * 3, "one RGB triplet per pixel")
        XCTAssertEqual(rgb, [30, 20, 10, 30, 20, 10, 30, 20, 10, 30, 20, 10])
    }

    // MARK: - Row stride

    /// A buffer whose rows are padded past `width * 4`. A walk that steps by `width * 4` reads
    /// progressively further into the previous row's padding as it descends the frame.
    func testRGBReorderFollowsRowStrideRatherThanPixelWidth() {
        let width = 250
        let height = 8
        let rowBytes = 1024
        var storage = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0..<height {
            for col in 0..<width {
                let offset = row * rowBytes + col * 4
                storage[offset] = UInt8(row)              // B
                storage[offset + 1] = UInt8(col % 256)    // G
                storage[offset + 2] = UInt8((row + col) % 256) // R
                storage[offset + 3] = 255                 // A
            }
        }

        let rgb = withBGRABytes(storage) { bgra in
            MoveNetThunderModel.rgb(from: bgra, rowBytes: rowBytes, width: width, height: height)
        }

        XCTAssertEqual(rgb.count, width * height * 3, "one RGB triplet per pixel")
        for row in 0..<height {
            for col in 0..<width {
                let index = (row * width + col) * 3
                XCTAssertEqual(rgb[index], UInt8((row + col) % 256), "R at row \(row) col \(col)")
                XCTAssertEqual(rgb[index + 1], UInt8(col % 256), "G at row \(row) col \(col)")
                XCTAssertEqual(rgb[index + 2], UInt8(row), "B at row \(row) col \(col)")
            }
        }
    }

    // MARK: - Fixture

    /// Hands the test-owned storage to the packing seam as an `UnsafePointer<UInt8>` without
    /// going through CoreVideo, so the stride under test is chosen by the test, not the allocator.
    private func withBGRABytes(
        _ storage: [UInt8],
        body: (UnsafePointer<UInt8>) -> [UInt8]
    ) -> [UInt8] {
        storage.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else {
                XCTFail("fixture storage is empty")
                return []
            }
            return body(baseAddress.assumingMemoryBound(to: UInt8.self))
        }
    }
}
