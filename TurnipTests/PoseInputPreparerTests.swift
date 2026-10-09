import CoreImage
import CoreVideo
import XCTest
@testable import Turnip

/// The one preprocess implementation both frame sources feed through. The live path's whole
/// premise is that the camera's native 420v frames can go straight in without an ISP conversion
/// to BGRA, so that is exercised here alongside the file path's BGRA.
final class PoseInputPreparerTests: XCTestCase {
    private let preparer = PoseInputPreparer(preprocessor: FramePreprocessor(targetWidth: 256, targetHeight: 256))

    func testBGRASourcePacksAFullTensorWithLetterboxGeometry() throws {
        let source = try makeBuffer(width: 640, height: 360, format: kCVPixelFormatType_32BGRA)

        let input = try preparer.prepare(source)

        XCTAssertEqual(input.tensor.count, 256 * 256 * 3)
        XCTAssertEqual(input.mapping.scale, 256.0 / 640, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.offsetX, 0, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.offsetY, (256 - 360 * 256.0 / 640) / 2, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.sourceExtent, CGRect(x: 0, y: 0, width: 640, height: 360))
    }

    /// The camera's native format. `CIImage(cvPixelBuffer:)` handles the planar-to-RGB conversion,
    /// and the 32BGRA contract is on the rendered target, not the source.
    func testBiPlanar420vSourceIsAccepted() throws {
        let source = try makeBuffer(width: 640, height: 360, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fill420v(source, luma: 200)

        let input = try preparer.prepare(source)

        XCTAssertEqual(input.tensor.count, 256 * 256 * 3)
        XCTAssertEqual(input.mapping.sourceExtent, CGRect(x: 0, y: 0, width: 640, height: 360))
        // The letterboxed content is bright and the pad stays black: sample the middle row and a
        // pad row. Video-range luma 200 with neutral chroma converts to a light gray.
        let middle = pixel(in: input.tensor, x: 128, y: 128)
        XCTAssertGreaterThan(middle.red, 150, "content row was not rendered from the 420v source")
        XCTAssertGreaterThan(middle.green, 150)
        XCTAssertGreaterThan(middle.blue, 150)
        let pad = pixel(in: input.tensor, x: 128, y: 2)
        XCTAssertEqual(pad.red, 0, "letterbox pad must stay zeroed")
        XCTAssertEqual(pad.green, 0)
        XCTAssertEqual(pad.blue, 0)
    }

    /// The crux of `prepare`'s live-path change: a rotated sensor buffer is uprighted before the
    /// letterbox runs, so the mapping (and therefore the frame-normalized keypoints it later
    /// inverts) is computed against the rotated dimensions, not the raw sensor ones — matching
    /// what the file path already gets for free from `VideoFrameSampler`'s `preferredTransform`.
    func testRotationUprightsBeforeLetterboxingSoTheMappingReflectsTheRotatedExtent() throws {
        let source = try makeBuffer(width: 640, height: 360, format: kCVPixelFormatType_32BGRA)

        let input = try preparer.prepare(source, rotationDegrees: 90)

        // 640x360 rotated 90° clockwise is 360x640 — portrait, the same shape a portrait
        // recording's movie connection reports — so the letterbox pads left/right, not top/bottom.
        XCTAssertEqual(input.mapping.sourceExtent, CGRect(x: 0, y: 0, width: 360, height: 640))
        XCTAssertEqual(input.mapping.scale, 256.0 / 640, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.offsetY, 0, accuracy: 1e-6)
        XCTAssertEqual(input.mapping.offsetX, (256 - 360 * 256.0 / 640) / 2, accuracy: 1e-6)
    }

    /// The mapping alone doesn't pin the render: it is a pure function of the rotated extent and
    /// says nothing about whether `prepare` actually rotates before letterboxing rather than
    /// after, or rotates at all. This renders real content through the full composition and
    /// checks where it lands, so dropping the rotation or reversing the composition order (both
    /// silently pass every other test in this file, since none of them fill the source buffer)
    /// fail here.
    ///
    /// Source: 640x360, left half (`x < 320`) bright, right half dark. A 90° clockwise rotation
    /// swings the left edge up to become the top edge (`FramePreprocessorTests`' rendered-fixture
    /// test pins that direction for a marked corner the same way), so the bright half should land
    /// in the top half of the rotated 360x640 frame, then scale 0.4 into the top half of the
    /// 256x256 tensor's content rows (`y` 0..<128, at `x` 56..<200 where the letterbox is unpadded
    /// — `offsetX` is 56, per the mapping test above). The bottom half (`y` 128..<256) must be
    /// dark, and rotating-then-letterboxing (rather than the reverse) is what keeps the content
    /// inside the target at all: letterbox-then-rotate would translate it outside the 256x256
    /// buffer entirely, rendering nothing.
    func testRotationRendersContentUprightBeforeLetterboxingNotAfter() throws {
        let source = try makeVerticalSplitBuffer(width: 640, height: 360, brightUntilColumn: 320)

        let input = try preparer.prepare(source, rotationDegrees: 90)

        let top = pixel(in: input.tensor, x: 128, y: 40)
        XCTAssertEqual(top.red, 255, "the source's left half must land in the tensor's top half")
        let bottom = pixel(in: input.tensor, x: 128, y: 210)
        XCTAssertEqual(bottom.red, 0, "the source's right half must land in the tensor's bottom half")
    }

    func testDegenerateSourceThrowsInsteadOfProducingGeometry() throws {
        // A 1x1 source is valid; the degenerate case is exercised through the preprocessor's
        // own guard, which `prepare` reaches with the CIImage extent.
        let tiny = try makeBuffer(width: 1, height: 1, format: kCVPixelFormatType_32BGRA)
        XCTAssertNoThrow(try preparer.prepare(tiny))
        XCTAssertThrowsError(
            try preparer.preprocessor.letterboxGeometry(forSourceExtent: .zero))
    }

    // MARK: - Fixtures

    private struct RGB {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private func pixel(in tensor: Data, x: Int, y: Int) -> RGB {
        let offset = (y * 256 + x) * 3
        return RGB(red: tensor[offset], green: tensor[offset + 1], blue: tensor[offset + 2])
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("CVPixelBufferCreate failed for format \(format) with status \(status)")
        }
        return buffer
    }

    /// A BGRA buffer bright for `x < brightUntilColumn`, dark everywhere else — full height, so
    /// the split is unambiguous under any rotation that swaps width and height. The buffer is
    /// fully filled and unlocked before this returns, so `preparer.prepare`'s own
    /// `CIImage(cvPixelBuffer:)` construction never races the fill.
    private func makeVerticalSplitBuffer(width: Int, height: Int, brightUntilColumn: Int) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                let value: UInt8 = col < brightUntilColumn ? 255 : 0
                let offset = row * bytesPerRow + col * 4
                base[offset] = value
                base[offset + 1] = value
                base[offset + 2] = value
                base[offset + 3] = 255
            }
        }
        return buffer
    }

    /// Solid luma with neutral chroma (128) in both planes.
    private func fill420v(_ buffer: CVPixelBuffer, luma: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0)
            memset(lumaPlane, Int32(luma), bytes)
        }
        if let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1)
            memset(chromaPlane, 128, bytes)
        }
    }
}
