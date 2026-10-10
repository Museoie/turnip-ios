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
/// A trick has to stand out from what the athlete is doing around it, not clear one fixed bar:
/// each sample's speed is divided by the median speed within `baselineHalfWindow` of it, so
/// bouncing on a sprung floor or walking back to the start sets the level a burst is measured
/// against. A burst starts above `entryRatio` and holds while it stays above `exitRatio`, which
/// keeps a trick whole through the moments mid-trick that read slower than its peak. Speeds at or
/// below `minimumSpeed` never count as motion, whatever the ratio — a still athlete's keypoint
/// jitter over a near-zero median would otherwise read as a burst.
///
/// Every duration is in seconds, so the analysis granularity setting changes how finely the
/// signal is sampled and nothing else.
struct TrickWindowDetector: Sendable {
    let entryRatio: Float
    let exitRatio: Float
    /// Torso lengths per second.
    let minimumSpeed: Float
    /// Half-width of the window the baseline is the median speed over. A burst longer than about
    /// this raises its own baseline, so a single trick or combo that keeps going for much longer
    /// can fall below `entryRatio` partway through.
    let baselineHalfWindow: TimeInterval
    /// Seconds of measured samples a baseline needs inside its window.
    let minimumBaselineCoverage: TimeInterval
    /// A burst shorter than this is a glitch, not a trick.
    let minimumSustainedSeconds: TimeInterval
    /// Unbroken quiet needed to call two bursts separate tricks.
    let minimumQuietSeconds: TimeInterval
    /// Seconds of buffer added before the detected motion starts.
    let leadingBufferSeconds: TimeInterval
    /// Seconds of buffer added after the detected motion ends. Larger than
    /// `leadingBufferSeconds`: the motion signal reads quiet as soon as the athlete slows on
    /// landing, which is consistently earlier than the trick visually reads as complete —
    /// absorbing the landing and any follow-through still takes another beat. A short trailing
    /// buffer cuts clips before the landing lands.
    let trailingBufferSeconds: TimeInterval

    init(
        entryRatio: Float = 2,
        exitRatio: Float = 1.4,
        minimumSpeed: Float = 2.5,
        baselineHalfWindow: TimeInterval = 5,
        minimumBaselineCoverage: TimeInterval = 1,
        minimumSustainedSeconds: TimeInterval = 0.3,
        minimumQuietSeconds: TimeInterval = 1,
        leadingBufferSeconds: TimeInterval = 1,
        trailingBufferSeconds: TimeInterval = 3
    ) {
        self.entryRatio = entryRatio
        self.exitRatio = exitRatio
        self.minimumSpeed = minimumSpeed
        self.baselineHalfWindow = baselineHalfWindow
        self.minimumBaselineCoverage = minimumBaselineCoverage
        self.minimumSustainedSeconds = minimumSustainedSeconds
        self.minimumQuietSeconds = minimumQuietSeconds
        self.leadingBufferSeconds = leadingBufferSeconds
        self.trailingBufferSeconds = trailingBufferSeconds
    }

    /// Durations are compared with this much slack: ten 0.1 s samples sum to just under 1 s.
    private static let durationTolerance: TimeInterval = 1e-6

    func detectWindows(in samples: [MotionSample]) -> [TrickWindow] {
        let states = states(of: samples)
        let sustained = runsOfMotion(in: states).filter { run in
            samples[run.upperBound].endTime - samples[run.lowerBound].startTime
                >= minimumSustainedSeconds - Self.durationTolerance
        }
        return merging(sustained, separatedBy: states, in: samples).map { burst in
            TrickWindow(
                startTime: max(0, samples[burst.lowerBound].startTime - leadingBufferSeconds),
                endTime: samples[burst.upperBound].endTime + trailingBufferSeconds
            )
        }
    }

    /// A sample with no speed — or no baseline to measure it against — is evidence of neither
    /// motion nor rest: it never contributes to the quiet stretch that would split two tricks,
    /// and a single unknown inside a burst does not end it — only a second consecutive unknown,
    /// or a quiet sample, does.
    private enum SampleState {
        /// Above `entryRatio`: can start a burst.
        case bursting
        /// Above `exitRatio`: can continue one.
        case moving
        case quiet
        case unknown
    }

    private func states(of samples: [MotionSample]) -> [SampleState] {
        let baselines = baselines(of: samples)
        return zip(samples, baselines).map { sample, baseline in
            guard let speed = sample.speed else { return .unknown }
            guard speed > minimumSpeed else { return .quiet }
            guard let baseline else { return .unknown }
            let ratio = speed / max(baseline, .leastNormalMagnitude)
            if ratio > entryRatio { return .bursting }
            return ratio > exitRatio ? .moving : .quiet
        }
    }

    /// The median known speed within `baselineHalfWindow` of each sample, by end time; nil where
    /// the window holds less than `minimumBaselineCoverage` of measured samples.
    private func baselines(of samples: [MotionSample]) -> [Float?] {
        let times = samples.map(\.endTime)
        let required = max(3, Int((minimumBaselineCoverage / samples.typicalSpacing).rounded()))
        var lower = 0
        var upper = 0
        return times.map { time in
            while times[lower] < time - baselineHalfWindow { lower += 1 }
            while upper < times.count, times[upper] <= time + baselineHalfWindow { upper += 1 }
            let known = samples[lower..<upper].compactMap(\.speed).map(Double.init)
            return known.count >= required ? Float(known.median) : nil
        }
    }

    /// A burst opens on a `.bursting` sample and runs through `.moving` and `.bursting` ones. A
    /// single unknown sample inside it does not close it: it is one frame pair of missing
    /// evidence — pose lost to blur mid-trick, typically — not evidence of rest, and closing at it
    /// would split a real trick below the sustained minimum and drop it. A second consecutive
    /// unknown, or a quiet sample, closes the burst at its last measured sample.
    private func runsOfMotion(in states: [SampleState]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var lastMoving = 0
        var bridgedUnknown = false

        for (index, state) in states.enumerated() {
            switch (state, start) {
            case (.bursting, nil):
                start = index
                lastMoving = index
            case (.bursting, .some), (.moving, .some):
                lastMoving = index
                bridgedUnknown = false
            case (.unknown, .some) where !bridgedUnknown:
                bridgedUnknown = true
            case (.unknown, .some(let begin)), (.quiet, .some(let begin)):
                runs.append(begin...lastMoving)
                start = nil
                bridgedUnknown = false
            default:
                break
            }
        }
        if let begin = start {
            runs.append(begin...lastMoving)
        }
        return runs
    }

    private func merging(
        _ bursts: [ClosedRange<Int>],
        separatedBy states: [SampleState],
        in samples: [MotionSample]
    ) -> [ClosedRange<Int>] {
        var merged: [ClosedRange<Int>] = []
        for burst in bursts {
            guard let previous = merged.last else {
                merged.append(burst)
                continue
            }
            let between = (previous.upperBound + 1)..<burst.lowerBound
            if longestQuietStretch(in: states, over: between, of: samples)
                >= minimumQuietSeconds - Self.durationTolerance {
                merged.append(burst)
            } else {
                merged[merged.count - 1] = previous.lowerBound...burst.upperBound
            }
        }
        return merged
    }

    /// Measures the longest unbroken quiet stretch rather than the gap between bursts, so motion
    /// too short to be its own trick still counts against the separation it sits in.
    private func longestQuietStretch(
        in states: [SampleState],
        over range: Range<Int>,
        of samples: [MotionSample]
    ) -> TimeInterval {
        var longest: TimeInterval = 0
        var current: TimeInterval = 0
        for index in range {
            if case .quiet = states[index] {
                current += samples[index].endTime - samples[index].startTime
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
