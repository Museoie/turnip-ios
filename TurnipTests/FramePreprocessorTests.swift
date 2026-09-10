import CoreVideo
import XCTest
@testable import Turnip

private struct FixtureFailure: Error {
    let message: String
}

final class FramePreprocessorTests: XCTestCase {

    // MARK: - Input shape

    func testInitReadsHeightBeforeWidth() throws {
        let preprocessor = try FramePreprocessor(inputShape: [1, 192, 256, 3])

        XCTAssertEqual(preprocessor.targetHeight, 192)
        XCTAssertEqual(preprocessor.targetWidth, 256)
    }

    func testInitRejectsShapeThatIsNotRankFour() {
        XCTAssertThrowsError(try FramePreprocessor(inputShape: [256, 256, 3]))
    }

    func testInitRejectsChannelCountThePackingCannotWrite() {
        XCTAssertThrowsError(try FramePreprocessor(inputShape: [1, 256, 256, 4]))
    }

    // MARK: - Geometry

    func testLetterboxMapsASquareSourceOntoTheInputSquare() {
        let preprocessor = FramePreprocessor(targetWidth: 256, targetHeight: 256)
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)

        let (transform, mapping) = preprocessor.letterboxGeometry(forSourceExtent: extent)

        XCTAssertEqual(transform.a, 0.5, accuracy: 0.0001)
        XCTAssertEqual(transform.d, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mapping.offsetX, 0, accuracy: 0.0001)
        XCTAssertEqual(mapping.offsetY, 0, accuracy: 0.0001)
        XCTAssertEqual(extent.applying(transform).width, 256, accuracy: 0.0001)
        XCTAssertEqual(extent.applying(transform).height, 256, accuracy: 0.0001)
    }

    /// The letterbox fit: the longer side fills the input, the shorter side is centered with
    /// zeroed padding — never an independent per-axis stretch, which is what fed MoveNet
    /// subjects squashed to 56% width (or stretched 1.78x) on every non-square frame.
    func testLetterboxFitsANonSquareSourceInsideTheInputSquare() {
        let preprocessor = FramePreprocessor(targetWidth: 256, targetHeight: 256)

        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
            let extent = CGRect(origin: .zero, size: size)
            let scaled = extent.applying(preprocessor.letterboxGeometry(forSourceExtent: extent).transform)

            XCTAssertLessThanOrEqual(scaled.width, 256.0001, "\(size) overflows the input square")
            XCTAssertLessThanOrEqual(scaled.height, 256.0001, "\(size) overflows the input square")
            XCTAssertEqual(max(scaled.width, scaled.height), 256, accuracy: 0.0001, "\(size) underfills it")
        }
    }

    func testLetterboxCentersLandscapeAndPortraitFrames() {
        let preprocessor = FramePreprocessor(targetWidth: 256, targetHeight: 256)

        // 1920x1080: uniform scale is 256/1920, so the frame is 256x144 and the 112 leftover
        // pixels split evenly above and below.
        let landscape = preprocessor.letterboxGeometry(forSourceExtent: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(landscape.mapping.scale, 256.0 / 1920.0, accuracy: 0.0001)
        XCTAssertEqual(landscape.mapping.offsetX, 0, accuracy: 0.0001)
        XCTAssertEqual(landscape.mapping.offsetY, 56, accuracy: 0.0001)
        let placedLandscape = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(landscape.transform)
        XCTAssertEqual(placedLandscape.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(placedLandscape.origin.y, 56, accuracy: 0.0001)
        XCTAssertEqual(placedLandscape.width, 256, accuracy: 0.0001)
        XCTAssertEqual(placedLandscape.height, 144, accuracy: 0.0001)

        // 1080x1920 (what portrait frames become once the preferredTransform fix lands): the
        // inverse — padding on the sides instead of top and bottom.
        let portrait = preprocessor.letterboxGeometry(forSourceExtent: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        XCTAssertEqual(portrait.mapping.scale, 256.0 / 1920.0, accuracy: 0.0001)
        XCTAssertEqual(portrait.mapping.offsetX, 56, accuracy: 0.0001)
        XCTAssertEqual(portrait.mapping.offsetY, 0, accuracy: 0.0001)
    }

    /// Keypoints come back in normalized input coordinates; the recorded (scale, offsetX, offsetY)
    /// must invert them exactly, since the crop-rect and empirical-baseline work depends on it.
    func testLetterboxMappingInvertsNormalizedKeypoints() {
        let preprocessor = FramePreprocessor(targetWidth: 256, targetHeight: 256)
        let mapping = preprocessor.letterboxGeometry(
            forSourceExtent: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        ).mapping

        // Center of the input square is the center of the source frame.
        let center = mapping.sourcePoint(normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertEqual(center.x, 960, accuracy: 0.0001)
        XCTAssertEqual(center.y, 540, accuracy: 0.0001)

        // The scaled frame occupies x in [0, 256], y in [56, 200] — the pad boundary maps back
        // to the frame edges, not into the padding.
        let topLeft = mapping.sourcePoint(normalizedX: 0, normalizedY: 56.0 / 256.0)
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.0001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.0001)
        let bottomRight = mapping.sourcePoint(normalizedX: 1, normalizedY: 200.0 / 256.0)
        XCTAssertEqual(bottomRight.x, 1920, accuracy: 0.0001)
        XCTAssertEqual(bottomRight.y, 1080, accuracy: 0.0001)
    }

    func testZeroFillClearsEveryByteIncludingRowPadding() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 250, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw FixtureFailure(message: "could not allocate a 250x8 buffer: \(status)")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            memset(
                baseAddress, 0xA5,
                CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
            )
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        FramePreprocessor.zeroFill(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw FixtureFailure(message: "could not read back the zeroed buffer")
        }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<bytesPerRow {
                XCTAssertEqual(bytes[row * bytesPerRow + col], 0, "byte \(col) of row \(row) not cleared")
            }
        }
    }

    // MARK: - Packing

    func testPackEmitsRGBTripletsFromABGRASource() throws {
        let preprocessor = FramePreprocessor(targetWidth: 2, targetHeight: 2)

        try withBGRABuffer(width: 2, height: 2, bytesPerRow: 8, fill: { _, _ in (b: 10, g: 20, r: 30) }) { buffer in
            let packed = try preprocessor.packRGB(from: buffer)

            XCTAssertEqual(packed.count, 2 * 2 * 3, "one RGB triplet per pixel")
            XCTAssertEqual(Array(packed), [30, 20, 10, 30, 20, 10, 30, 20, 10, 30, 20, 10])
        }
    }

    /// A buffer whose rows are padded past `width * 4`. A walk that steps by `width * 4` reads
    /// progressively further into the previous row's padding as it descends the frame.
    func testPackFollowsRowStrideRatherThanPixelWidth() throws {
        let width = 250
        let height = 8
        let bytesPerRow = 1024
        let preprocessor = FramePreprocessor(targetWidth: width, targetHeight: height)

        let fill: (Int, Int) -> (b: UInt8, g: UInt8, r: UInt8) = { row, col in
            (b: UInt8(row), g: UInt8(col % 256), r: UInt8((row + col) % 256))
        }

        try withBGRABuffer(width: width, height: height, bytesPerRow: bytesPerRow, fill: fill) { buffer in
            XCTAssertEqual(
                CVPixelBufferGetBytesPerRow(buffer), bytesPerRow,
                "fixture is only meaningful if CoreVideo kept the padded stride"
            )

            let packed = try Array(preprocessor.packRGB(from: buffer))
            XCTAssertEqual(packed.count, width * height * 3)

            for row in 0..<height {
                for col in 0..<width {
                    let expected = fill(row, col)
                    let index = (row * width + col) * 3
                    XCTAssertEqual(packed[index], expected.r, "R at row \(row) col \(col)")
                    XCTAssertEqual(packed[index + 1], expected.g, "G at row \(row) col \(col)")
                    XCTAssertEqual(packed[index + 2], expected.b, "B at row \(row) col \(col)")
                }
            }
        }
    }

    func testPackRejectsABufferOfADifferentSize() throws {
        let preprocessor = FramePreprocessor(targetWidth: 2, targetHeight: 2)

        try withBGRABuffer(width: 4, height: 4, bytesPerRow: 16, fill: { _, _ in (b: 1, g: 2, r: 3) }) { buffer in
            XCTAssertThrowsError(try preprocessor.packRGB(from: buffer))
        }
    }

    func testPackRejectsANonBGRAPixelFormat() throws {
        let preprocessor = FramePreprocessor(targetWidth: 2, targetHeight: 2)

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw FixtureFailure(message: "could not allocate a 420YpCbCr8 buffer: \(status)")
        }

        XCTAssertThrowsError(try preprocessor.packRGB(from: buffer))
    }

    // MARK: - Fixture

    /// Builds a BGRA pixel buffer over test-owned storage so `bytesPerRow` is chosen by the test
    /// rather than by the allocator. The storage outlives `body` and nothing escapes it.
    private func withBGRABuffer(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        fill: (Int, Int) -> (b: UInt8, g: UInt8, r: UInt8),
        body: (CVPixelBuffer) throws -> Void
    ) throws {
        var storage = [UInt8](repeating: 0, count: bytesPerRow * height)
        for row in 0..<height {
            for col in 0..<width {
                let pixel = fill(row, col)
                let offset = row * bytesPerRow + col * 4
                storage[offset] = pixel.b
                storage[offset + 1] = pixel.g
                storage[offset + 2] = pixel.r
                storage[offset + 3] = 255
            }
        }

        try storage.withUnsafeMutableBytes { raw in
            guard let baseAddress = raw.baseAddress else {
                throw FixtureFailure(message: "empty fixture storage")
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreateWithBytes(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                baseAddress, bytesPerRow, nil, nil, nil, &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw FixtureFailure(message: "could not wrap fixture storage in a pixel buffer: \(status)")
            }
            try body(buffer)
        }
    }
}
