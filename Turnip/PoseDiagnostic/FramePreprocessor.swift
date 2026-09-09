import CoreGraphics
import CoreVideo
import Foundation

/// Scales a decoded frame to the model's input size and packs it as the interleaved RGB uint8
/// buffer MoveNet's `[1, height, width, 3]` input tensor expects.
///
/// A value type separate from `MoveNetThunderModel` because all of this is pure geometry and byte
/// walking, while the model can only be constructed from a bundled `.tflite` that is deliberately
/// not in the repository — so as long as the scale computation and the BGRA→RGB walk live on the
/// actor, nothing can exercise them.
struct FramePreprocessor {
    /// Channels the packing writes per pixel. A model whose input tensor disagrees is rejected in
    /// `init(inputShape:)` rather than fed a buffer of the wrong length.
    static let channelCount = 3

    let targetWidth: Int
    let targetHeight: Int

    init(targetWidth: Int, targetHeight: Int) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
    }

    /// Derives the target size from the model's own input tensor dimensions, in the tensor's
    /// `[batch, height, width, channels]` order.
    init(inputShape: [Int]) throws {
        guard inputShape.count == 4 else {
            throw PoseDiagnosticError.inferenceFailed("Unexpected model input shape: \(inputShape)")
        }
        guard inputShape[3] == Self.channelCount else {
            throw PoseDiagnosticError.inferenceFailed(
                "Model input wants \(inputShape[3]) channels, the frame packing writes \(Self.channelCount)"
            )
        }
        self.init(targetWidth: inputShape[2], targetHeight: inputShape[1])
    }

    func scaleTransform(forSourceExtent extent: CGRect) -> CGAffineTransform {
        CGAffineTransform(
            scaleX: CGFloat(targetWidth) / extent.width,
            y: CGFloat(targetHeight) / extent.height
        )
    }

    /// Allocates the destination the scaled frame is rendered into, at the model's input size.
    func makeTargetBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, targetWidth, targetHeight, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw PoseDiagnosticError.inferenceFailed("Failed to allocate resize buffer")
        }
        return buffer
    }

    /// Reads a BGRA frame already at the model's input size and returns interleaved RGB bytes.
    func packRGB(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            throw PoseDiagnosticError.inferenceFailed(
                "Frame packing wants a 32BGRA buffer, got pixel format \(pixelFormat)"
            )
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width == targetWidth, height == targetHeight else {
            throw PoseDiagnosticError.inferenceFailed(
                "Frame buffer is \(width)x\(height), model input is \(targetWidth)x\(targetHeight)"
            )
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw PoseDiagnosticError.inferenceFailed("Failed to access resized pixel buffer")
        }

        // Rows are padded to the allocator's alignment, so the walk steps by bytesPerRow rather
        // than width * 4 — the two differ for most widths and drift compounds down the frame.
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bgra = baseAddress.assumingMemoryBound(to: UInt8.self)

        var rgb = [UInt8](repeating: 0, count: targetWidth * targetHeight * Self.channelCount)
        for row in 0..<targetHeight {
            let rowStart = row * bytesPerRow
            for col in 0..<targetWidth {
                let pixelOffset = rowStart + col * 4
                let outIndex = (row * targetWidth + col) * Self.channelCount
                rgb[outIndex] = bgra[pixelOffset + 2]     // R
                rgb[outIndex + 1] = bgra[pixelOffset + 1] // G
                rgb[outIndex + 2] = bgra[pixelOffset]     // B
            }
        }

        return Data(rgb)
    }
}
