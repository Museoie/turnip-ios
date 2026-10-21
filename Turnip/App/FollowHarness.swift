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
///   clip).
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

    static let movieURL: URL = makeMovie()

    static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.movieURL
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

    /// Detection's crop for the window: the static rect around every joint in it.
    static var cropRect: NormalizedRect {
        let framesInWindow = poseFrames.filter { $0.timestamp >= window.startTime && $0.timestamp <= window.endTime }
        return CropRectCalculator().cropRect(for: framesInWindow, renderedPixelSize: size)
            ?? NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
    }

    private static func makeMovie() -> URL {
        let url = URL.temporaryDirectory.appending(path: "FollowHarness.mov")
        try? FileManager.default.removeItem(at: url)
        do {
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
            guard writer.canAdd(input) else { throw HarnessError.failed }
            writer.add(input)
            guard writer.startWriting() else { throw HarnessError.failed }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<(seconds * Int(fps)) {
                let deadline = Date().addingTimeInterval(15)
                while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
                    throw HarnessError.failed
                }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
                guard let buffer = pixelBuffer else { throw HarnessError.failed }
                draw(frame: frame, into: buffer)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
                else { throw HarnessError.failed }
            }
            input.markAsFinished()
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            finished.wait()
            guard writer.status == .completed else { throw HarnessError.failed }
            return url
        } catch {
            Logger(subsystem: "com.hoiekim.turnip", category: "FollowHarness")
                .error("follow movie encode failed: \(String(describing: error), privacy: .public)")
            return URL(fileURLWithPath: "/dev/null")
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

    private enum HarnessError: Error {
        case failed
    }
}

/// `-screenshotClipEditorFollow`: see `FollowHarness`.
struct ScreenshotFollowEditorHarness: View {
    var body: some View {
        NavigationStack {
            ClipEditorView(
                source: ClipEditorSource(
                    window: FollowHarness.window,
                    cropRect: FollowHarness.cropRect,
                    framingMode: CommandLine.arguments.contains("-follow") ? .follow : .still,
                    asset: AVURLAsset(url: FollowHarness.movieURL),
                    poseFrames: FollowHarness.poseFrames),
                onCommit: { _ in },
                onDelete: {})
        }
    }
}

/// `-screenshotClipListFollow`: see `FollowHarness`.
struct ScreenshotFollowClipListHarness: View {
    var body: some View {
        NavigationStack {
            ClipListView(
                items: [
                    ClipListItem(window: FollowHarness.window, cropRect: FollowHarness.cropRect, framingMode: .follow)
                ],
                poseFrames: FollowHarness.poseFrames,
                asset: AVURLAsset(url: FollowHarness.movieURL),
                assetIdentifier: "screenshot",
                duration: Double(FollowHarness.seconds))
        }
    }
}
#endif
