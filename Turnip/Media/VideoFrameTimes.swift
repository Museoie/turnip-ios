import AVFoundation
import Foundation

/// When a video track's frames are shown: the presentation times of its samples over a range
/// of source time. A preview that moves in step with the picture has to change exactly when
/// the picture does, and a variable-frame-rate take doesn't put its frames on a nominal grid.
///
/// Reads the samples' timing without decoding them (`AVAssetReaderTrackOutput` with no output
/// settings), so a few seconds of 60 fps video costs a few hundred small reads.
struct VideoFrameTimes: Sendable {
    /// The range the times were read over.
    let range: ClosedRange<TimeInterval>
    /// Ascending.
    let times: [TimeInterval]

    /// `nil` when the asset has no video track or can't be read.
    static func load(from asset: AVAsset, over range: ClosedRange<TimeInterval>) async -> VideoFrameTimes? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: max(range.lowerBound, 0), preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
            guard reader.startReading() else { return nil }
            var times: [TimeInterval] = []
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if time.isNumeric { times.append(time.seconds) }
            }
            guard reader.status == .completed else { return nil }
            return VideoFrameTimes(range: range, times: times.sorted())
        }.value
    }

    /// The frames shown from `span.lowerBound` through `span.upperBound`, and the first one
    /// after it — the frame on which whatever ends with the span is first seen. `nil` when the
    /// span isn't inside the range read.
    func frames(across span: ClosedRange<TimeInterval>) -> [TimeInterval]? {
        guard span.lowerBound >= range.lowerBound, span.upperBound <= range.upperBound else { return nil }
        guard let firstAfter = times.firstIndex(where: { $0 > span.upperBound }) else {
            return times.filter { $0 >= span.lowerBound }
        }
        return times[..<firstAfter].filter { $0 >= span.lowerBound } + [times[firstAfter]]
    }

    /// `frames(across:)` on a regular grid of `frameRate`, for before the real times are read.
    static func nominalFrames(across span: ClosedRange<TimeInterval>, frameRate: Double) -> [TimeInterval] {
        guard frameRate > 0 else { return [] }
        let first = Int((span.lowerBound * frameRate).rounded(.up))
        let last = Int((span.upperBound * frameRate).rounded(.down)) + 1
        guard first <= last else { return [] }
        return (first...last).map { TimeInterval($0) / frameRate }
    }
}
