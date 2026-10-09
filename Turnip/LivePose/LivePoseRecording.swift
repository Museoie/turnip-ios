import Foundation
import os

/// The inference side of one recording: drains a `LivePoseSampleChannel` through the pose model
/// and collects results in dequeue order, which is timestamp order.
///
/// Owned by the recording, not the camera screen (docs/LIVE_POSE.md "Inference side"): each
/// Record tap makes a new one, and every path that ends a recording either finishes it — the
/// consumer drains and completes seconds later — or cancels it. A consumer that outlives its
/// recording is always the one for that recording.
///
/// Takes the inference as a closure rather than the model actor so the drain's branches — the
/// error ending, the cancelled ending, the metrics merge — can be exercised with a stub; the
/// model itself only exists on a device with the bundled `.tflite`.
final class LivePoseRecording: Sendable {
    typealias Inference = @Sendable (PoseModelInput) async throws -> [PoseKeypoint]
    /// Called with each result as soon as it is scored, off the main actor, so a live consumer
    /// (the camera preview overlay) can show it while the recording is still running.
    typealias ResultHandler = @Sendable (PoseFrameResult) -> Void

    let channel: LivePoseSampleChannel
    private let producerMetrics: OSAllocatedUnfairLock<LivePoseMetrics?>
    private let drain: Task<LivePoseOutcome, Never>

    init(
        inference: @escaping Inference,
        channel: LivePoseSampleChannel,
        onResult: @escaping ResultHandler = { _ in }
    ) {
        self.channel = channel
        let producerMetrics = OSAllocatedUnfairLock<LivePoseMetrics?>(initialState: nil)
        self.producerMetrics = producerMetrics
        drain = Task(priority: .userInitiated) {
            await Self.drain(
                channel: channel, inference: inference, onResult: onResult, producerMetrics: producerMetrics)
        }
    }

    /// The capture side is done: record what it measured and let the consumer drain.
    func finish(producer metrics: LivePoseMetrics) {
        producerMetrics.withLock { $0 = metrics }
        channel.finish()
    }

    /// Stop as soon as the in-flight sample is scored. `metrics` may be nil when the capture side
    /// already finished and only the drain is being cut short.
    func cancel(producer metrics: LivePoseMetrics?) {
        if let metrics {
            producerMetrics.withLock { $0 = metrics }
        }
        channel.cancel()
    }

    func outcome() async -> LivePoseOutcome {
        await drain.value
    }

    /// An inference failure also closes the channel — nothing further can be scored — but it is
    /// reported through `errorMessage`, and `wasCancelled` stays false: that ending has a review
    /// to show, where an abandoned recording has none.
    private static func drain(
        channel: LivePoseSampleChannel,
        inference: Inference,
        onResult: ResultHandler,
        producerMetrics: OSAllocatedUnfairLock<LivePoseMetrics?>
    ) async -> LivePoseOutcome {
        var results: [PoseFrameResult] = []
        var inferenceStats = DurationStats()
        var errorMessage: String?
        while let sample = await channel.next() {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let keypoints = try await inference(sample.input)
                inferenceStats.record(ProcessInfo.processInfo.systemUptime - start)
                let result = PoseFrameResult(
                    frameIndex: sample.frameIndex, timestamp: sample.timestamp, keypoints: keypoints)
                PoseResultLogger.log(result)
                results.append(result)
                onResult(result)
            } catch {
                errorMessage = (error as? PoseError)?.errorDescription ?? error.localizedDescription
                channel.cancel()
            }
        }
        var metrics = producerMetrics.withLock { $0 } ?? LivePoseMetrics()
        let stats = channel.stats
        metrics.framesInferred = results.count
        metrics.inference = inferenceStats
        metrics.queueDrops = stats.dropCount
        metrics.maxQueueDepth = stats.maxDepth
        metrics.wasCancelled = errorMessage == nil && channel.isCancelled
        return LivePoseOutcome(results: results, metrics: metrics, errorMessage: errorMessage)
    }
}
