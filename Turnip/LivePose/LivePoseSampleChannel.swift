import Foundation
import os

/// One kept live frame, already reduced to its model input. Holds no reference to the pixel buffer
/// it came from, so the capture output can recycle that buffer as soon as the delegate callback
/// returns.
struct LivePoseSample: Sendable {
    /// The frame's approximate index in the written file: file-relative time × capture frame rate.
    /// Approximate because the live path never sees the file's own sample numbering.
    let frameIndex: Int
    /// File-relative, see `LivePoseTimestampAnchor`.
    let timestamp: TimeInterval
    let input: PoseModelInput
}

/// The hand-off between the capture queue (a synchronous delegate callback that cannot await)
/// and the inference consumer (an async loop). A `BoundedSampleQueue` under a lock, plus one
/// parked continuation for the consumer to wait on when the queue is empty.
///
/// Single consumer by contract: exactly one `LivePoseRecording` drains a channel, so at most one
/// `next()` is ever in flight. `finish()` lets the consumer drain what is queued and then return
/// nil — inference is allowed to lag behind the recording and finish after it. `cancel()` empties
/// the queue first, so the consumer returns nil immediately after the sample it is on.
final class LivePoseSampleChannel: Sendable {
    /// 30 samples ≈ 3 s at the normal rate and ≈ 6 MB of tensors: a few seconds of lag before the
    /// oldest work is shed, small enough that shedding is what happens instead of memory growth.
    static let defaultCapacity = 30

    struct Stats: Equatable, Sendable {
        let dropCount: Int
        let maxDepth: Int
        let pushCount: Int
    }

    private struct State {
        var queue: BoundedSampleQueue<LivePoseSample>
        var waiter: CheckedContinuation<LivePoseSample?, Never>?
        var isFinished = false
        var isCancelled = false
    }

    private enum Pending {
        case sample(LivePoseSample)
        case finished
        case parked
    }

    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int = LivePoseSampleChannel.defaultCapacity) {
        state = OSAllocatedUnfairLock(initialState: State(queue: BoundedSampleQueue(capacity: capacity)))
    }

    var stats: Stats {
        state.withLock { state in
            Stats(dropCount: state.queue.dropCount, maxDepth: state.queue.maxDepth, pushCount: state.queue.pushCount)
        }
    }

    var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    /// Producer side. A push after `finish()` or `cancel()` is dropped silently: the recording it
    /// belonged to is over.
    func push(_ sample: LivePoseSample) {
        let handoff: (CheckedContinuation<LivePoseSample?, Never>, LivePoseSample)? = state.withLock { state in
            guard !state.isFinished else { return nil }
            state.queue.push(sample)
            guard let waiter = state.waiter, let next = state.queue.pop() else { return nil }
            state.waiter = nil
            return (waiter, next)
        }
        if let (waiter, next) = handoff {
            waiter.resume(returning: next)
        }
    }

    /// Consumer side: the oldest queued sample, waiting for one if the queue is empty; nil once
    /// the channel is finished and drained, or cancelled.
    func next() async -> LivePoseSample? {
        await withCheckedContinuation { continuation in
            let pending: Pending = state.withLock { state in
                if let sample = state.queue.pop() {
                    return .sample(sample)
                }
                if state.isFinished {
                    return .finished
                }
                precondition(state.waiter == nil, "LivePoseSampleChannel has one consumer; a second next() is a bug")
                state.waiter = continuation
                return .parked
            }
            switch pending {
            case .sample(let sample):
                continuation.resume(returning: sample)
            case .finished:
                continuation.resume(returning: nil)
            case .parked:
                break
            }
        }
    }

    /// No more pushes will come; the consumer drains what is queued, then sees nil.
    func finish() {
        close(discardingQueued: false)
    }

    /// Nothing queued will be consumed; the consumer sees nil as soon as it asks.
    func cancel() {
        close(discardingQueued: true)
    }

    private func close(discardingQueued: Bool) {
        let waiter: CheckedContinuation<LivePoseSample?, Never>? = state.withLock { state in
            state.isFinished = true
            if discardingQueued {
                state.isCancelled = true
                state.queue.removeAll()
            }
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        // A parked waiter means the queue was already empty, so there is nothing left to drain.
        waiter?.resume(returning: nil)
    }
}
