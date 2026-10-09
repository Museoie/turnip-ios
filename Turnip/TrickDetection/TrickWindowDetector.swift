import Foundation

/// A detected trick's time range in the source video, in seconds.
///
/// `endTime` carries the trailing buffer and can therefore sit past the last sampled frame;
/// clip trimming clamps it to the asset's duration. Two windows may overlap where their
/// buffers meet — each is a standalone clip of its own trick, not a partition of the video.
struct TrickWindow: Hashable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// Peak-detects the motion signal into trick windows (docs/DESIGN.md's pipeline step 5).
///
/// `minimumSustainedSamples`/`minimumQuietSamples` default to the design doc's durations (300 ms
/// / 1 s) rounded to samples at `sampleRate` — the signal is one sample per kept frame pair, so
/// at the shipped default of 10 samples/sec that is 3 and 10 samples, scaling freely (floored at
/// 1 sample) in both directions as `sampleRate` moves. `displacementThreshold` defaults to a
/// rate-scaled value for the same reason, but only scales *down* above the shipped default rate
/// — see `scaledDisplacementThreshold` below for why it stays fixed rather than also scaling up
/// below it. Passing any of `displacementThreshold`/`minimumSustainedSamples`/
/// `minimumQuietSamples` explicitly overrides its derivation, for a caller (tests) that wants an
/// exact value regardless of rate.
struct TrickWindowDetector: Sendable {
    /// Normalized units per sample.
    let displacementThreshold: Float
    /// Consecutive samples above threshold before a burst counts as a trick.
    let minimumSustainedSamples: Int
    /// Unbroken quiet samples needed to call two peaks separate tricks.
    let minimumQuietSamples: Int
    /// Seconds of buffer added before the detected motion starts.
    let leadingBufferSeconds: TimeInterval
    /// Seconds of buffer added after the detected motion ends. Larger than
    /// `leadingBufferSeconds`: the motion signal reads "quiet" as soon as the athlete's
    /// translation slows on landing, which is consistently earlier than the trick visually
    /// reads as complete — absorbing the landing and any follow-through still takes another
    /// beat. A short trailing buffer cuts clips before the landing lands.
    let trailingBufferSeconds: TimeInterval

    private static let sustainedSeconds = 0.3
    private static let quietSeconds = 1.0
    /// `displacementThreshold`'s calibrated value at `VideoFrameSampler.targetSamplesPerSecond`
    /// — see `scaledDisplacementThreshold` below for why it doesn't stay fixed across rates.
    private static let displacementThresholdAtBaseRate: Float = 0.05

    init(
        displacementThreshold: Float? = nil,
        minimumSustainedSamples: Int? = nil,
        minimumQuietSamples: Int? = nil,
        sampleRate: Int = VideoFrameSampler.targetSamplesPerSecond,
        leadingBufferSeconds: TimeInterval = 1,
        trailingBufferSeconds: TimeInterval = 3
    ) {
        self.displacementThreshold = displacementThreshold
            ?? Self.scaledDisplacementThreshold(sampleRate: sampleRate)
        self.minimumSustainedSamples = minimumSustainedSamples
            ?? Self.sampleCount(seconds: Self.sustainedSeconds, sampleRate: sampleRate)
        self.minimumQuietSamples = minimumQuietSamples
            ?? Self.sampleCount(seconds: Self.quietSeconds, sampleRate: sampleRate)
        self.leadingBufferSeconds = leadingBufferSeconds
        self.trailingBufferSeconds = trailingBufferSeconds
    }

    /// `MotionSample.displacement` is a raw positional delta between two *consecutive*
    /// samples, not a velocity — so the same real motion covers proportionally less distance
    /// as `sampleRate` rises, since denser samples land closer together in time. Scaling
    /// `displacementThresholdAtBaseRate` by the baseline rate over the actual one keeps the
    /// effective velocity threshold roughly constant, so raising Settings' analysis
    /// granularity samples motion more finely instead of silently raising the bar a trick's
    /// motion has to clear to register as moving at all. ("Roughly" — `VideoFrameSampler`
    /// quantizes the achieved rate to `round(fps / stride)`, so it can differ slightly from
    /// the configured one; the same approximation `minimumSustainedSamples`/
    /// `minimumQuietSamples` already carry.)
    ///
    /// Only scales *down*, never up: below the baseline rate, a naive scale-up (0.5 at
    /// `sampleRate == 1`) demands more real per-sample motion than trick footage actually
    /// produces, so nothing would be detected at that end of the granularity range.
    /// `max(sampleRate, ...)` floors the denominator at the baseline, so a rate below it keeps
    /// the un-scaled (more permissive) base threshold.
    private static func scaledDisplacementThreshold(sampleRate: Int) -> Float {
        guard sampleRate > 0 else { return displacementThresholdAtBaseRate }
        let flooredRate = max(sampleRate, VideoFrameSampler.targetSamplesPerSecond)
        return displacementThresholdAtBaseRate
            * Float(VideoFrameSampler.targetSamplesPerSecond) / Float(flooredRate)
    }

    /// Rounds a duration to whole samples at `sampleRate`, floored at 1 — a zero-sample
    /// threshold would trigger on any single moving/quiet sample instead of requiring the
    /// sustained/quiet run the design doc specifies.
    private static func sampleCount(seconds: Double, sampleRate: Int) -> Int {
        max(1, Int((seconds * Double(sampleRate)).rounded()))
    }

    func detectWindows(in samples: [MotionSample]) -> [TrickWindow] {
        let states = samples.map(state(of:))
        let sustained = runsOfMotion(in: states).filter { $0.count >= minimumSustainedSamples }

        return merging(sustained, separatedBy: states).map { peak in
            TrickWindow(
                startTime: max(0, samples[peak.lowerBound].startTime - leadingBufferSeconds),
                endTime: samples[peak.upperBound].endTime + trailingBufferSeconds
            )
        }
    }

    /// A sample with no displacement is evidence of neither motion nor rest: it never
    /// contributes to the quiet stretch that would split two tricks, and a single unknown
    /// inside a burst does not end the run of motion — only a second consecutive unknown,
    /// or a quiet sample, does.
    private enum SampleState {
        case moving
        case quiet
        case unknown
    }

    private func state(of sample: MotionSample) -> SampleState {
        guard let displacement = sample.displacement else { return .unknown }
        return displacement > displacementThreshold ? .moving : .quiet
    }

    /// A single unknown sample inside a burst does not terminate the run: it is an
    /// anchor-identity seam — e.g. a dropout that outlasts the reconstruction bound — one
    /// frame of missing evidence, not evidence of rest. This is the design doc's layer-5
    /// reasoning (a 33 ms dropout carries no signal either way) applied to the state machine:
    /// closing the run at the seam would split a real trick below the sustained minimum and
    /// drop it entirely. The seam must be isolated: a second consecutive unknown closes the
    /// run at the last moving sample, so sustained pose loss still ends a trick.
    private func runsOfMotion(in states: [SampleState]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        /// Index of the tolerated unknown inside the open run, if one is being bridged.
        var openSeam: Int?

        /// The run's last sample when everything before `index` belongs to the run.
        func endOfOpenRun(excluding index: Int) -> Int {
            (openSeam ?? index) - 1
        }

        for index in states.indices {
            switch states[index] {
            case .moving:
                if start == nil { start = index }
                openSeam = nil
            case .unknown:
                if start != nil, openSeam == nil {
                    openSeam = index
                } else if let begin = start {
                    runs.append(begin...endOfOpenRun(excluding: index))
                    start = nil
                    openSeam = nil
                }
            case .quiet:
                if let begin = start {
                    runs.append(begin...endOfOpenRun(excluding: index))
                    start = nil
                    openSeam = nil
                }
            }
        }
        if let begin = start {
            runs.append(begin...endOfOpenRun(excluding: states.count))
        }
        return runs
    }

    private func merging(
        _ peaks: [ClosedRange<Int>],
        separatedBy states: [SampleState]
    ) -> [ClosedRange<Int>] {
        var merged: [ClosedRange<Int>] = []

        for peak in peaks {
            guard let previous = merged.last else {
                merged.append(peak)
                continue
            }
            let between = (previous.upperBound + 1)..<peak.lowerBound
            if longestQuietRun(in: states, over: between) >= minimumQuietSamples {
                merged.append(peak)
            } else {
                merged[merged.count - 1] = previous.lowerBound...peak.upperBound
            }
        }
        return merged
    }

    /// Measures the longest unbroken quiet stretch rather than the distance between peaks, so a
    /// burst too short to be its own trick still counts against the separation it sits in.
    private func longestQuietRun(in states: [SampleState], over range: Range<Int>) -> Int {
        var longest = 0
        var current = 0

        for index in range {
            if case .quiet = states[index] {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
