import CoreGraphics
import Foundation

/// The pose frames the camera scored live for a take its live pass did not cover end to end
/// (docs/LIVE_POSE.md "From results to clips"): a thermal backoff, a shed sample, a drain cut
/// short. They are valid where they exist, so Processing keeps them and analyzes only the
/// stretches they miss (`PoseBackfill`) instead of decoding the whole take again.
///
/// Held on the pushed `SelectedVideo` and in `VideoLibraryViewModel`'s per-session store as a
/// `PoseFrameStore`: packed frames in a `tmp/` scratch file, deleted when the partial is
/// discarded and swept at launch when a session died before that (docs/PRIVACY.md). Never in
/// `Documents/`, never backed up, never off the device.
struct PartialPoseFrames: Hashable, Sendable {
    /// The live-scored frames, packed and on disk, shared by reference: copies of this value
    /// read the same file, and the file is deleted when the last copy is gone (or when the
    /// store is discarded). Equality is by store identity: two partials are equal when they
    /// carry the same stored recording, not merely the same frames.
    let store: PoseFrameStore
    /// The spacing the live pass sampled at: 1 / the granularity it was armed with. The gaps are
    /// filled at this spacing too, not at whatever granularity Processing is set to by the time
    /// it runs, so the merged take is one grid and its motion signal one rate.
    let interval: TimeInterval
    /// What the live keypoints are normalized against (`LivePoseCoverage.renderedPixelSize`), for
    /// the crop step when nothing needs filling and no file frame supplies a render size.
    let renderedPixelSize: CGSize

    init(store: PoseFrameStore, interval: TimeInterval, renderedPixelSize: CGSize) {
        self.store = store
        self.interval = interval
        self.renderedPixelSize = renderedPixelSize
    }

    /// A partial from frames already in memory — for tests and for call sites that build one
    /// without a drain. Writes the frames to a fresh store.
    init(frames: [MultiPoseFrame], interval: TimeInterval, renderedPixelSize: CGSize) throws {
        self.store = try PoseFrameStore(frames: frames)
        self.interval = interval
        self.renderedPixelSize = renderedPixelSize
    }
}

/// A sample with a place on a take's timeline, which is all `PoseBackfill.merged` needs of it.
protocol TimestampedSample {
    var timestamp: TimeInterval { get }
}

extension PoseFrameResult: TimestampedSample {}
extension MultiPoseFrame: TimestampedSample {}

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
    static func merged<Frame: TimestampedSample>(
        live: [Frame], backfilled: [Frame], interval: TimeInterval
    ) -> [Frame] {
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

/// The live and backfilled frames as one timestamp-ordered take, streamed: the iterator
/// pulls from whichever store is earlier, dropping a backfilled frame that lands within
/// half an interval of a live sample — the same rule `merged` applies, so the two agree
/// frame for frame. Re-iterable: each iteration opens fresh store sequences, so the
/// pipeline can pass over the merged take once for the signal and again for the crop
/// frames, without ever holding it as an array.
struct MergedPoseFrames: Sequence {
    private let live: PoseFrameStore
    private let backfilled: PoseFrameStore
    private let interval: TimeInterval
    /// Frames at or past the end of the file are dropped on either side, as `backfill`
    /// drops the live ones: the camera keeps scoring between Stop and its hand-off, and
    /// a backfilled sample past the end is no frame at all.
    private let duration: TimeInterval

    init(live: PoseFrameStore, backfilled: PoseFrameStore, interval: TimeInterval, duration: TimeInterval) {
        self.live = live
        self.backfilled = backfilled
        self.interval = interval
        self.duration = duration
    }

    func makeIterator() -> Iterator {
        Iterator(
            live: live.frames().makeIterator(),
            backfilled: backfilled.frames().makeIterator(),
            interval: interval,
            duration: duration)
    }

    struct Iterator: IteratorProtocol {
        private var live: AnyIterator<MultiPoseFrame>
        private var backfilled: AnyIterator<MultiPoseFrame>
        private let interval: TimeInterval
        private let duration: TimeInterval
        private var livePeek: MultiPoseFrame?
        private var backfilledPeek: MultiPoseFrame?
        /// The last live frame emitted: with `livePeek` (the next live frame) it brackets
        /// any backfilled frame, so the nearest live time is one of the two — both
        /// sequences are timestamp-ordered, so no other live frame can be nearer.
        private var previousLive: MultiPoseFrame?

        init(
            live: AnyIterator<MultiPoseFrame>, backfilled: AnyIterator<MultiPoseFrame>,
            interval: TimeInterval, duration: TimeInterval
        ) {
            self.live = live
            self.backfilled = backfilled
            self.interval = interval
            self.duration = duration
        }

        mutating func next() -> MultiPoseFrame? {
            while true {
                if livePeek == nil {
                    livePeek = nextLive()
                }
                if backfilledPeek == nil {
                    backfilledPeek = nextBackfilled()
                }
                guard let backfilledFrame = backfilledPeek else {
                    // No backfilled frame left: the rest is live, in order.
                    let frame = livePeek
                    livePeek = nil
                    if let frame {
                        previousLive = frame
                    }
                    return frame
                }
                guard let liveFrame = livePeek else {
                    // No live frame left (or none within the file): the rest is backfilled,
                    // kept unless it lands on a live sample already emitted.
                    backfilledPeek = nil
                    if let previous = previousLive,
                       abs(backfilledFrame.timestamp - previous.timestamp) < interval / 2 {
                        continue
                    }
                    return backfilledFrame
                }
                if liveFrame.timestamp <= backfilledFrame.timestamp {
                    livePeek = nil
                    previousLive = liveFrame
                    return liveFrame
                }
                // The backfilled frame is earlier than the next live frame: keep it unless
                // it lands within half an interval of the live frame either side of it.
                backfilledPeek = nil
                let before = previousLive.map { abs(backfilledFrame.timestamp - $0.timestamp) } ?? .infinity
                let after = liveFrame.timestamp - backfilledFrame.timestamp
                if Swift.min(before, after) < interval / 2 {
                    continue
                }
                return backfilledFrame
            }
        }

        /// The next live frame inside the file, skipping the ones past its end.
        private mutating func nextLive() -> MultiPoseFrame? {
            while let frame = live.next() {
                if frame.timestamp < duration {
                    return frame
                }
            }
            return nil
        }

        /// The next backfilled frame inside the file, skipping the ones past its end.
        /// The sampler only asks for times inside the file, so this is a guard, not a
        /// path the backfill flow reaches — the merge keeps the same contract on both
        /// sides rather than trusting one of them.
        private mutating func nextBackfilled() -> MultiPoseFrame? {
            while let frame = backfilled.next() {
                if frame.timestamp < duration {
                    return frame
                }
            }
            return nil
        }
    }
}
