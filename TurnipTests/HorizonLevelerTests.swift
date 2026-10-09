import AVFoundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import Turnip

/// Synthetic horizons for the leveling tests: a blue sky over dark ground, the boundary
/// through the frame's center tilted by `tilt` in the screen convention — y down,
/// positive clockwise, so the right end of a positive-tilt horizon sits lower on screen.
/// Each side shades with its distance from the horizon: the detector reads nothing off
/// two flat fields meeting at a line, and nothing off a shading that runs down the frame
/// instead of away from the horizon, but it reads this scene within an eighth of a
/// degree for tilts of a few degrees either way (the range a handheld clip's roll lives
/// in). It reports no horizon at all for a tilt of exactly zero, so the fixtures keep
/// clear of it.
enum HorizonVideoFixture {
    /// The tilt the fixtures use: clearly off level, clearly one-sided, so a sign error
    /// can't pass as a rounding one — and inside the range the detector reads reliably.
    static let tilt = 5.0 * .pi / 180

    /// The pixel at (`x`, `y`), y down from the top, as BGRA bytes in that order — the
    /// `kCVPixelFormatType_32BGRA` layout the movie frames and the image below both use.
    static func pixel(x: Int, y: Int, width: Int, height: Int, tilt: Double) -> SIMD4<UInt8> {
        // Signed distance from the horizon, positive below it.
        let dx = Double(x) - Double(width) / 2, dy = Double(y) - Double(height) / 2
        let distance = -dx * sin(tilt) + dy * cos(tilt)
        let depth = min(1, abs(distance) / Double(max(height, 1)))
        if distance < 0 {
            return SIMD4(230, UInt8(170 + 30 * depth), UInt8(120 + 60 * depth), 255)
        }
        return SIMD4(UInt8(50 - 20 * depth), UInt8(110 - 30 * depth), UInt8(90 - 30 * depth), 255)
    }

    /// A `width`x`height` image of the tilted horizon, upright.
    static func image(width: Int, height: Int, tilt: Double) throws -> CGImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let bgra = pixel(x: x, y: y, width: width, height: height, tilt: tilt)
                let base = (y * width + x) * 4
                for channel in 0..<4 {
                    data[base + channel] = bgra[channel]
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(data) as CFData))
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Writes a one-second movie of the tilted horizon. `width`/`height` are the *encoded*
    /// frame's; with a `transform`, the horizon is drawn so that it shows at `tilt` once
    /// the track is uprighted through it — a portrait recording stored on its side, the
    /// way iPhones store them. `rollSamples` adds a `RollTrack` metadata track, so a test
    /// can give the picture and the track different answers.
    static func write(
        tilt: Double, width: Int, height: Int, transform: CGAffineTransform = .identity, fps: Int32 = 30,
        rollSamples: [(time: TimeInterval, tilt: Double)]? = nil
    ) async throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "HorizonVideoFixture-\(UUID().uuidString).mov")
        let output = try startWriting(
            to: url, width: width, height: height, transform: transform, withRollTrack: rollSamples != nil)
        // The displayed frame: the encoded rect's corners through the transform. Encoded
        // pixels map into it so the horizon can be drawn in displayed space.
        let displayed = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
        let toDisplayed = transform.concatenating(
            CGAffineTransform(translationX: -displayed.minX, y: -displayed.minY))
        for frameIndex in 0..<Int(fps) {
            while !output.input.isReadyForMoreMediaData, output.writer.status == .writing {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let pixelBuffer = try makePixelBuffer(from: output.adaptor)
            fill(pixelBuffer, width: width, height: height) { x, y in
                let shown = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(toDisplayed)
                return pixel(
                    x: Int(shown.x), y: Int(shown.y),
                    width: Int(abs(displayed.width).rounded()), height: Int(abs(displayed.height).rounded()),
                    tilt: tilt)
            }
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            guard output.adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw output.writer.error ?? PoseError.videoLoadFailed(underlying: nil)
            }
        }
        if let rollTrack = output.rollTrack, let rollSamples {
            try await rollTrack.append(rollSamples, writer: output.writer)
        }
        output.input.markAsFinished()
        await output.writer.finishWriting()
        guard output.writer.status == .completed else {
            throw output.writer.error ?? PoseError.videoLoadFailed(underlying: nil)
        }
        return url
    }

    private struct Output {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let rollTrack: TestRollTrackWriter?
    }

    /// An H.264 writer with one BGRA video input (and a roll track's metadata input when
    /// asked), started and ready for frames.
    private static func startWriting(
        to url: URL, width: Int, height: Int, transform: CGAffineTransform, withRollTrack: Bool = false
    ) throws -> Output {
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
            ])
        guard writer.canAdd(input) else { throw XCTSkip("AVAssetWriter cannot add a video input here") }
        writer.add(input)
        let rollTrack = withRollTrack ? try TestRollTrackWriter.add(to: writer) : nil
        guard writer.startWriting() else { throw writer.error ?? PoseError.videoLoadFailed(underlying: nil) }
        writer.startSession(atSourceTime: .zero)
        return Output(writer: writer, input: input, adaptor: adaptor, rollTrack: rollTrack)
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw PoseError.videoLoadFailed(underlying: nil) }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else { throw PoseError.videoLoadFailed(underlying: nil) }
        return pixelBuffer
    }

    /// Fills a BGRA pixel buffer from `pixel`, called with each encoded pixel's (x, y).
    private static func fill(
        _ pixelBuffer: CVPixelBuffer, width: Int, height: Int, pixel: (Int, Int) -> SIMD4<UInt8>
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let bgra = pixel(x, y)
                let offset = y * bytesPerRow + x * 4
                for channel in 0..<4 {
                    bytes[offset + channel] = bgra[channel]
                }
            }
        }
    }
}

final class HorizonLevelerTests: XCTestCase {
    private let tilt = HorizonVideoFixture.tilt

    // MARK: - Pure pieces

    func testSampleTimesSitInsideTheWindow() {
        let times = HorizonLeveler.sampleTimes(in: TrickWindow(startTime: 2, endTime: 4), count: 4)

        XCTAssertEqual(times, [2.25, 2.75, 3.25, 3.75])
    }

    func testSampleTimesAreEmptyForAnEmptyWindow() {
        XCTAssertTrue(HorizonLeveler.sampleTimes(in: TrickWindow(startTime: 2, endTime: 2)).isEmpty)
        XCTAssertTrue(HorizonLeveler.sampleTimes(in: TrickWindow(startTime: 2, endTime: 4), count: 0).isEmpty)
    }

    func testLevelingRotationCancelsTheMeanTilt() throws {
        // Tilts drifting from 0.1 to 0.3 over the window average 0.2: the leveling turn
        // is the opposite 0.2.
        let rotation = try XCTUnwrap(HorizonLeveler.levelingRotation(forHorizonTilts: [0.1, 0.2, 0.3]))

        XCTAssertEqual(rotation, -0.2, accuracy: 0.0001)
    }

    func testLevelingRotationIsNilWithNoTilts() {
        XCTAssertNil(HorizonLeveler.levelingRotation(forHorizonTilts: []))
    }

    // MARK: - Vision

    /// The sign test: a horizon whose right end sits lower on screen (clockwise, positive
    /// in the screen convention) must read as a positive tilt. Vision's documentation
    /// doesn't say which way its angle runs; this pins it.
    func testHorizonTiltReadsAClockwiseHorizonAsPositive() throws {
        let image = try HorizonVideoFixture.image(width: 640, height: 360, tilt: tilt)

        let measured = try XCTUnwrap(HorizonLeveler.horizonTilt(in: image), "the detector found no horizon")

        XCTAssertEqual(measured, tilt, accuracy: 0.03)
    }

    func testHorizonTiltReadsACounterclockwiseHorizonAsNegative() throws {
        let image = try HorizonVideoFixture.image(width: 640, height: 360, tilt: -tilt)

        let measured = try XCTUnwrap(HorizonLeveler.horizonTilt(in: image), "the detector found no horizon")

        XCTAssertEqual(measured, -tilt, accuracy: 0.03)
    }

    // MARK: - Over a clip

    func testLevelingRotationOverAClipCancelsItsTilt() async throws {
        let url = try await HorizonVideoFixture.write(tilt: tilt, width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: url) }

        let rotation = try await HorizonLeveler.levelingRotation(
            in: AVURLAsset(url: url), window: TrickWindow(startTime: 0, endTime: 1))

        XCTAssertEqual(try XCTUnwrap(rotation), -tilt, accuracy: 0.03)
    }

    /// A portrait recording stored on its side: the horizon is level-ish only once the
    /// track is uprighted, so this fails if the frames are sampled in encoded orientation.
    func testLevelingRotationMeasuresASidewaysStoredTrackUpright() async throws {
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let url = try await HorizonVideoFixture.write(tilt: tilt, width: 320, height: 180, transform: rotate90)
        defer { try? FileManager.default.removeItem(at: url) }

        let rotation = try await HorizonLeveler.levelingRotation(
            in: AVURLAsset(url: url), window: TrickWindow(startTime: 0, endTime: 1))

        XCTAssertEqual(try XCTUnwrap(rotation), -tilt, accuracy: 0.03)
    }

    func testLevelingRotationIsNilWhenNoFrameDecodes() async throws {
        let rotation = try await HorizonLeveler.levelingRotation(
            in: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            window: TrickWindow(startTime: 0, endTime: 1))

        XCTAssertNil(rotation)
    }
}
