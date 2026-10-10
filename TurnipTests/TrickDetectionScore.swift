import Foundation
@testable import Turnip

/// How a video's detected clips line up with its hand-labelled tricks — the measure the
/// detection evaluation (`TrickDetectionEvaluationTests`) reports.
///
/// A trick is caught when one clip covers at least `caughtCoverage` of it, partial when a clip
/// touches it but none covers that much, and missed when no clip touches it. A clip touching no
/// labelled trick is a false positive. Coverage is per clip, not the union of clips: a trick
/// split across two clips is not one clip a user can keep.
struct TrickDetectionScore: Equatable {
    enum Outcome: Character {
        case caught = "C"
        case partial = "P"
        case missed = "M"
    }

    static let caughtCoverage = 0.8

    /// One outcome per labelled trick, in label order.
    let outcomes: [Outcome]
    let falsePositives: Int
    /// Total clip length, buffers included and not clamped to the video's duration.
    let clipSeconds: TimeInterval

    init(windows: [TrickWindow], tricks: [ClosedRange<TimeInterval>]) {
        outcomes = tricks.map { trick in
            let coverage = windows.map { Self.overlap($0, trick) / (trick.upperBound - trick.lowerBound) }.max() ?? 0
            if coverage >= Self.caughtCoverage - 1e-9 { return .caught }
            return coverage > 0 ? .partial : .missed
        }
        falsePositives = windows.filter { window in tricks.allSatisfy { Self.overlap(window, $0) <= 0 } }.count
        clipSeconds = windows.reduce(0) { $0 + $1.endTime - $1.startTime }
    }

    var caught: Int { count(.caught) }
    var partial: Int { count(.partial) }
    var missed: Int { count(.missed) }

    /// Outcomes in label order then the false positives, e.g. `PPMCC+1fp`.
    var summary: String {
        String(outcomes.map(\.rawValue)) + "+\(falsePositives)fp"
    }

    private func count(_ outcome: Outcome) -> Int {
        outcomes.filter { $0 == outcome }.count
    }

    private static func overlap(_ window: TrickWindow, _ trick: ClosedRange<TimeInterval>) -> TimeInterval {
        max(0, min(window.endTime, trick.upperBound) - max(window.startTime, trick.lowerBound))
    }
}

/// Scores summed over several videos.
struct TrickDetectionTally: Equatable {
    var caught = 0
    var partial = 0
    var missed = 0
    var falsePositives = 0
    var clipSeconds: TimeInterval = 0

    mutating func add(_ score: TrickDetectionScore) {
        caught += score.caught
        partial += score.partial
        missed += score.missed
        falsePositives += score.falsePositives
        clipSeconds += score.clipSeconds
    }

    var summary: String {
        "caught \(caught)  partial \(partial)  missed \(missed)  false positives \(falsePositives)  "
            + "clip seconds \(Int(clipSeconds.rounded()))"
    }
}
