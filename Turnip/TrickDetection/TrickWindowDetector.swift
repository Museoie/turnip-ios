import Foundation

/// A detected trick's time range in the source video, in seconds.
///
/// `endTime` carries the trailing buffer and can therefore sit past the last sampled frame;
/// clip trimming clamps it to the asset's duration. Two windows may overlap where their
/// buffers meet — each is a standalone clip of its own trick, not a partition of the video.
struct TrickWindow: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// Peak-detects the motion signal into trick windows (docs/DESIGN.md's pipeline step 5).
///
/// Defaults are the design doc's, expressed in samples rather than seconds because the signal
/// is one sample per kept frame pair: at 30 fps with the sampler's stride of 3, 3 samples is
/// ~300 ms and 10 samples is ~1 s.
struct TrickWindowDetector: Sendable {
    /// Normalized units per sample.
    let displacementThreshold: Float
    /// Consecutive samples above threshold before a burst counts as a trick.
    let minimumSustainedSamples: Int
    /// Unbroken quiet samples needed to call two peaks separate tricks.
    let minimumQuietSamples: Int
    let bufferSeconds: TimeInterval

    init(
        displacementThreshold: Float = 0.05,
        minimumSustainedSamples: Int = 3,
        minimumQuietSamples: Int = 10,
        bufferSeconds: TimeInterval = 1
    ) {
        self.displacementThreshold = displacementThreshold
        self.minimumSustainedSamples = minimumSustainedSamples
        self.minimumQuietSamples = minimumQuietSamples
        self.bufferSeconds = bufferSeconds
    }

    func detectWindows(in samples: [MotionSample]) -> [TrickWindow] {
        let states = samples.map(state(of:))
        let sustained = runsOfMotion(in: states).filter { $0.count >= minimumSustainedSamples }

        return merging(sustained, separatedBy: states).map { peak in
            TrickWindow(
                startTime: max(0, samples[peak.lowerBound].startTime - bufferSeconds),
                endTime: samples[peak.upperBound].endTime + bufferSeconds
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
