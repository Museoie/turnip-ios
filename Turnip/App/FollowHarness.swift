#if DEBUG
import AVFoundation
import os
import SwiftUI

/// A take with something to follow, for the follow-mode harnesses and their UI tests: a
/// landscape movie in which a white bar — the athlete — crosses a grey frame, with pose
/// frames tracking it. The bar carries the frame's index in eight binary blocks, four on
/// each side of it, so a recording shows which source frame is on screen next to where the follow crop
/// put it: a pan in step with the picture holds the bar still in the marker frame by frame.
///
/// - `-screenshotClipEditorFollow`: the editor over the take's middle, in Still (add
///   `-follow` to open it in Follow, the way Settings' Follow the athlete opens a detected
///   clip, or `-keyframedZoom` to open it in Follow on `keyframedCrop`, whose zoom and turn
///   change from keyframe to keyframe).
/// - `-screenshotClipListFollow`: the Clip List with that clip in Follow, for the tile, its
///   poster and the expansion flight's card.
enum FollowHarness {
    static let size = CGSize(width: 640, height: 360)
    static let fps: Int32 = 30
    static let seconds = 6
    static let window = TrickWindow(startTime: 0.5, endTime: 5.5)

    /// The bar's center across the frame at `time`: still until 1 s, then across at a steady
    /// pace with an ease at either end, still again from 5 s.
    static func barCenterX(at time: TimeInterval) -> CGFloat {
        let progress = min(max((time - 1) / 4, 0), 1)
        let eased = progress * progress * (3 - 2 * progress)
        return 120 + CGFloat(eased) * 400
    }

    static let movie = makeMovie()

    static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.movie
        }
    }

    /// The stick figure around the bar, ten samples a second.
    static let poseFrames: [PoseFrameResult] = (0...(seconds * 10)).map { index in
        let time = Double(index) / 10
        let centerX = barCenterX(at: time)
        let keypoints = ScreenshotProcessingPoseRunner.sampleKeypoints.map { point in
            PoseKeypoint(
                name: point.name,
                y: Float((180 + (CGFloat(point.y) - 0.52) * 200) / size.height),
                x: Float((centerX + (CGFloat(point.x) - 0.5) * 70) / size.width),
                confidence: point.confidence)
        }
        return PoseFrameResult(frameIndex: index * 3, timestamp: time, keypoints: keypoints)
    }

    /// A follow crop on the bar whose zoom and turn change between its keyframes: 0.8× level,
    /// then 1.5× turned 0.5 rad clockwise, then 1× turned 0.3 rad back past level, then 0.8×
    /// level. The whole bar stays inside the marker throughout.
    static var keyframedCrop: FollowCrop {
        let zooms: [(scale: CGFloat, rotation: Double)] = [(0.8, 0), (1.5, 0.5), (1, -0.3), (0.8, 0)]
        return FollowCrop(
            keyframes: zip([1.5, 2.5, 3.5, 4.5], zooms).map { time, zoom in
                FollowKeyframe(
                    time: time, center: CGPoint(x: barCenterX(at: time), y: 180), scale: zoom.scale,
                    rotationRadians: zoom.rotation)
            },
            resting: FollowFraming(center: CGPoint(x: size.width / 2, y: 180), scale: 1, rotationRadians: 0),
            isAutoFollow: false)
    }

    /// Detection's crop for the window: the static rect around every joint in it.
    static var cropRect: NormalizedRect {
        let framesInWindow = poseFrames.filter { $0.timestamp >= window.startTime && $0.timestamp <= window.endTime }
        return CropRectCalculator().cropRect(for: framesInWindow, renderedPixelSize: size)
            ?? NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
    }

    /// The take, encoded once per build (`HarnessMovieFile`), or why it couldn't be: the
    /// failure is drawn over the harness (`HarnessMovieGate`) and logged, and the URL falls
    /// back to `/dev/null`, the editor's load-failure state. The time it took is logged either way.
    private static func makeMovie() -> ScreenshotSampleMovie {
        let logger = Logger(subsystem: "com.hoiekim.turnip", category: "FollowHarness")
        let started = Date()
        do {
            let file = try HarnessMovieFile.movie(named: "FollowHarness") { try encodeMovie(to: $0) }
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            let how = file.reused ? "reused" : "encoded"
            logger.notice("follow movie \(how, privacy: .public) in \(elapsed, privacy: .public) s")
            return ScreenshotSampleMovie(url: file.url, failure: nil)
        } catch {
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            let failure = "follow movie encode failed: \(error) after \(elapsed) s"
            logger.error("\(failure, privacy: .public)")
            return ScreenshotSampleMovie(url: URL(fileURLWithPath: "/dev/null"), failure: failure)
        }
    }

    private static func encodeMovie(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = Int(size.width), height = Int(size.height)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else { throw ScreenshotMovieError.setupFailed("can't add the video input") }
        writer.add(input)
        guard writer.startWriting() else { throw ScreenshotMovieError.writerFailed(step: "start", error: writer.error) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * Int(fps)) {
            try appendFrame(frame, adaptor: adaptor, input: input, writer: writer)
        }
        input.markAsFinished()
        try finishSampleMovieWriting(writer: writer)
    }

    private static func appendFrame(
        _ frame: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws {
        let deadline = Date().addingTimeInterval(15)
        while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard input.isReadyForMoreMediaData else {
            throw ScreenshotMovieError.notReady(writer: writer, input: "video", frame: frame)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw ScreenshotMovieError.writerFailed(step: "pixel buffer pool at frame \(frame)", error: writer.error)
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ScreenshotMovieError.setupFailed("pixel buffer at frame \(frame): CVReturn \(status)")
        }
        draw(frame: frame, into: buffer)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
            throw ScreenshotMovieError.writerFailed(step: "append video frame \(frame)", error: writer.error)
        }
    }

    /// Grey, the bar 24 px wide and 200 tall at mid-height, and beside it the frame index's
    /// eight bits, low bit leftmost, as 8 px blocks.
    private static func draw(frame: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer), width = CVPixelBufferGetWidth(buffer)
        memset(base, 70, rowBytes * height)
        func fill(x: Int, y: Int, width fillWidth: Int, height fillHeight: Int) {
            let left = max(x, 0), right = min(x + fillWidth, width)
            guard right > left else { return }
            for row in max(y, 0)..<min(y + fillHeight, height) {
                memset(base + row * rowBytes + left * 4, 255, (right - left) * 4)
            }
        }
        let center = Int(barCenterX(at: Double(frame) / Double(fps)).rounded())
        fill(x: center - 12, y: 80, width: 24, height: 200)
        for bit in 0..<8 where frame & (1 << bit) != 0 {
            fill(x: center - 44 + bit * 8 + (bit < 4 ? 0 : 24), y: 140, width: 8, height: 8)
        }
    }

}

/// `-screenshotClipEditorFollow`: see `FollowHarness`.
struct ScreenshotFollowEditorHarness: View {
    private static let isKeyframed = CommandLine.arguments.contains("-keyframedZoom")

    var body: some View {
        HarnessMovieGate(FollowHarness.movie) { movie in
            NavigationStack {
                ClipEditorView(
                    source: ClipEditorSource(
                        window: FollowHarness.window,
                        cropRect: FollowHarness.cropRect,
                        framingMode: CommandLine.arguments.contains("-follow") || Self.isKeyframed ? .follow : .still,
                        followCrop: Self.isKeyframed ? FollowHarness.keyframedCrop : nil,
                        asset: AVURLAsset(url: movie.url),
                        poseFrames: FollowHarness.poseFrames),
                    onCommit: { _ in },
                    onDelete: {})
            }
        }
    }
}

/// `-screenshotClipListFollow`: see `FollowHarness`.
struct ScreenshotFollowClipListHarness: View {
    var body: some View {
        HarnessMovieGate(FollowHarness.movie) { movie in
            NavigationStack {
                NameClipsView(
                    items: [
                        ClipListItem(
                            window: FollowHarness.window, cropRect: FollowHarness.cropRect, framingMode: .follow)
                    ],
                    poseFrames: FollowHarness.poseFrames,
                    asset: AVURLAsset(url: movie.url),
                    assetIdentifier: "screenshot",
                    duration: Double(FollowHarness.seconds))
            }
        }
    }
}
#endif
