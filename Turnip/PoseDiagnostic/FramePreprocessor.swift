import CoreGraphics
import CoreVideo
import Foundation

/// Records how a source frame was placed into the model's square input, so downstream work can
/// invert the mapping: MoveNet returns keypoints in normalized input coordinates, and once the
/// frame is letterboxed instead of stretched those coordinates no longer invert with a plain
/// per-axis scale. The inverse is `sourceX = (x * inputWidth - offsetX) / scale`, and likewise
/// for y — see `sourcePoint(normalizedX:normalizedY:)`.
struct LetterboxMapping: Sendable, Equatable {
    /// The single uniform scale applied to both axes, so the longer side exactly fills the input.
    /// Uniform because the pose model was trained on naturally-proportioned people — stretching
    /// the frame would feed it limb-length ratios it never saw in training.
    let scale: CGFloat
    /// Centering offsets, in input-tensor pixels. The scaled frame occupies
    /// `(offsetX, offsetY)..(offsetX + sourceWidth * scale, offsetY + sourceHeight * scale)`,
    /// and everything outside that rect is the zeroed pad region.
    let offsetX: CGFloat
    let offsetY: CGFloat
    /// The model's input size in pixels, needed to invert normalized keypoint coordinates.
    let inputSize: CGSize

    /// Maps a normalized keypoint coordinate (0–1 in the model's input space) back to the source
    /// frame's pixel coordinates. Pass `keypoint.x` as `normalizedX` and `keypoint.y` as
    /// `normalizedY` — MoveNet emits y before x, so the call site keeps the order explicit.
    func sourcePoint(normalizedX x: CGFloat, normalizedY y: CGFloat) -> CGPoint {
        CGPoint(
            x: (x * inputSize.width - offsetX) / scale,
            y: (y * inputSize.height - offsetY) / scale
        )
    }
}

/// Scales a decoded frame to the model's input size and packs it as the interleaved RGB uint8
/// buffer MoveNet's `[1, height, width, 3]` input tensor expects.
///
/// A value type separate from `MoveNetThunderModel` because all of this is pure geometry and byte
/// walking, while the model can only be constructed from a bundled `.tflite` that is deliberately
/// not in the repository — so as long as the scale computation and the BGRA→RGB walk live on the
/// actor, nothing can exercise them.
struct FramePreprocessor {
    /// Channels the packing writes per pixel. A model whose input tensor disagrees is rejected
    /// at load in `MoveNetThunderModel.init` before this type is constructed; the rank and
    /// channel guards in `init(inputShape:)` below are defense-in-depth for direct construction.
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

    /// The geometry that maps a source frame into the model's square input: a uniform scale that
    /// preserves aspect ratio plus the centering translation that letterboxes the remainder —
    /// every iPhone recording is non-square, so an independent per-axis scale would stretch the
    /// subject on the only path there is. Computed in one place so the forward transform and the
    /// `LetterboxMapping` that inverts it can never disagree.
    func letterboxGeometry(forSourceExtent extent: CGRect) -> (
        transform: CGAffineTransform, mapping: LetterboxMapping
    ) {
        let scale = min(CGFloat(targetWidth) / extent.width, CGFloat(targetHeight) / extent.height)
        let offsetX = (CGFloat(targetWidth) - extent.width * scale) / 2
        let offsetY = (CGFloat(targetHeight) - extent.height * scale) / 2
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        let mapping = LetterboxMapping(
            scale: scale, offsetX: offsetX, offsetY: offsetY,
            inputSize: CGSize(width: targetWidth, height: targetHeight)
        )
        return (transform, mapping)
    }

    /// Allocates the destination the scaled frame is rendered into, at the model's input size.
    /// The buffer is zero-filled before it is handed back: `CVPixelBufferCreate` does not zero
    /// the allocation, and the letterbox pad region is never written by the render — without the
    /// clear, uninitialized memory would reach the model as image data.
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
        Self.zeroFill(buffer)
        return buffer
    }

    /// Zeroes every byte of `pixelBuffer`. A separate static so tests can exercise the clear
    /// directly — a fresh `CVPixelBufferCreate` allocation reads as zeros either way, which makes
    /// `makeTargetBuffer`'s clearing invisible to a test that only reads the returned buffer.
    static func zeroFill(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        memset(
            baseAddress, 0,
            CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        )
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
