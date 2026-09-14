import AVFoundation
import CoreVideo
import XCTest
@testable import Turnip

/// Writes tiny H.264 movies so tests have something real to decode through AVAssetReader
/// (bundling fixture .mov files would be larger and opaque). Shared by the sampler tests and
/// the pipeline regression tests.
enum TestVideoWriter {
    /// Writes a `frameCount`-frame solid-color movie. `transform` is written as the track's
    /// preferredTransform — e.g. a 90° rotation to mimic an iPhone portrait recording stored
    /// as landscape-encoded frames.
    static func writeTestVideo(
        frameCount: Int, width: Int, height: Int, fps: Int32,
        transform: CGAffineTransform = .identity
    ) async throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "TestVideoWriter-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw XCTSkip("AVAssetWriter cannot add a video input on this platform")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? PoseError.videoLoadFailed(underlying: nil)
        }
        writer.startSession(atSourceTime: .zero)

        try await appendFrames(
            frameCount: frameCount,
            fps: fps,
            input: input,
            adaptor: adaptor,
            writer: writer
        )

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? PoseError.videoLoadFailed(underlying: nil)
        }
        return url
    }

    private static func appendFrames(
        frameCount: Int,
        fps: Int32,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter
    ) async throws {
        for frameIndex in 0..<frameCount {
            // Bounded on writer status: if the writer fails mid-write, `isReadyForMoreMediaData`
            // never becomes true, and without this check the loop would spin until XCTest's
            // timeout with no cause. Exiting instead lets `append` below surface `writer.error`.
            while !input.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw PoseError.videoLoadFailed(underlying: nil)
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw PoseError.videoLoadFailed(underlying: nil)
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
                // Vary the fill per frame so the encoder emits real (non-skipped) frames.
                memset(base, Int32(frameIndex * 20 % 255), byteCount)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? PoseError.videoLoadFailed(underlying: nil)
            }
        }
    }
}
