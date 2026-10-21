import CoreGraphics
import Foundation

/// The pose frames the camera scored live for a take its live pass did not cover end to end
/// (docs/LIVE_POSE.md "From results to clips"): a thermal backoff, a shed sample, a drain cut
/// short. They are valid where they exist, so Processing keeps them and analyzes only the
/// stretches they miss (`PoseBackfill`) instead of decoding the whole take again.
///
/// Held in memory only — on the pushed `SelectedVideo` and in `VideoLibraryViewModel`'s
/// per-session store — never written to disk: docs/PRIVACY.md has v1 persisting no pose data.
struct PartialPoseFrames: Hashable, Sendable {
    /// File-relative, in timestamp order.
    let frames: [PoseFrameResult]
    /// The spacing the live pass sampled at: 1 / the granularity it was armed with. The gaps are
    /// filled at this spacing too, not at whatever granularity Processing is set to by the time
    /// it runs, so the merged take is one grid and its motion signal one rate.
    let interval: TimeInterval
    /// What the live keypoints are normalized against (`LivePoseCoverage.renderedPixelSize`), for
    /// the crop step when nothing needs filling and no file frame supplies a render size.
    let renderedPixelSize: CGSize
}

/// Plans and merges the file samples that fill the gaps in a take's live pose frames. Pure, so the
/// grid arithmetic is testable without a video file.
enum PoseBackfill {
    /// Consecutive samples further apart than this many intervals have a gap between them. Above
    /// 1 because live spacing jitters by up to a capture frame around the grid (a 24 fps capture
    /// at 10 samples/s lands kept frames 0.083–0.125 s apart); below 2 so a stretch at the
    /// halved thermal rate counts as gaps.
    static let gapFactor = 1.5

    /// The file times to sample so that, together with `scored`, the take reads as one grid at
    /// `interval` over `0..<duration`. Each gap is filled forward from the sample before it, one
    /// interval at a time, stopping more than half an interval short of the sample after it; a
    /// gap at the head is filled backward from the first sample, and one at the tail forward to
    /// the end of the file. No scored samples at all means the whole take.
    static func wantedTimes(
        scored: [TimeInterval], interval: TimeInterval, duration: TimeInterval
    ) -> [TimeInterval] {
        guard interval > 0, duration > 0 else { return [] }
        guard let first = scored.first, let last = scored.last else {
            return grid(from: 0, step: interval, while: { $0 < duration })
        }
        var wanted: [TimeInterval] = grid(from: first - interval, step: -interval, while: { $0 > -interval / 2 })
            .map { max($0, 0) }
            .reversed()
        for (earlier, later) in zip(scored, scored.dropFirst()) where later - earlier > interval * gapFactor {
            wanted += grid(from: earlier + interval, step: interval, while: { $0 < later - interval / 2 })
        }
        wanted += grid(from: last + interval, step: interval, while: { $0 < duration })
        return wanted
    }

    /// `live` and `backfilled` as one timestamp-ordered take. A file frame lands at or after the
    /// time it was wanted for, so it can drift up against the live sample after its gap; one
    /// closer than half an interval to any live sample is dropped, because the motion signal
    /// divides displacement by the time between samples and keypoint jitter over a few
    /// milliseconds reads as a burst.
    static func merged(
        live: [PoseFrameResult], backfilled: [PoseFrameResult], interval: TimeInterval
    ) -> [PoseFrameResult] {
        let liveTimes = live.map(\.timestamp).sorted()
        let kept = backfilled.filter { frame in
            distanceToNearest(frame.timestamp, in: liveTimes) >= interval / 2
        }
        return (live + kept).sorted { $0.timestamp < $1.timestamp }
    }

    /// Binary search: a long take has thousands of samples on each side.
    private static func distanceToNearest(_ time: TimeInterval, in sorted: [TimeInterval]) -> TimeInterval {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let after = low < sorted.count ? sorted[low] - time : .infinity
        let before = low > 0 ? time - sorted[low - 1] : .infinity
        return min(after, before)
    }

    /// `start`, `start + step`, … for as long as `condition` holds. Multiplied out from `start`
    /// rather than accumulated, so a long gap does not drift off the grid.
    private static func grid(
        from start: TimeInterval, step: TimeInterval, while condition: (TimeInterval) -> Bool
    ) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var index = 0.0
        while condition(start + index * step) {
            times.append(start + index * step)
            index += 1
        }
        return times
    }
}
