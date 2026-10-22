import Foundation
@testable import Turnip

/// A hand-labelled trick: when it happened and, on footage with several people, who did it.
///
/// `labels.json` writes one as `[start, end]` seconds, or as an object that also names the
/// person: `{"window": [start, end], "person": "teal shirt", "at": [x, y]}`. `person` is for
/// whoever reads the labels. `at` is roughly where that person is mid-trick, as fractions of the
/// displayed frame's width and height from its top-left corner, the space a clip's
/// `NormalizedRect` crop is in; a trick with `at` is caught only if one of the clips covering
/// it frames that point.
struct LabelledTrick: Equatable {
    struct Position: Equatable {
        let x: Float
        let y: Float
    }

    let window: ClosedRange<TimeInterval>
    let person: String?
    let position: Position?

    init(window: ClosedRange<TimeInterval>, person: String? = nil, position: Position? = nil) {
        self.window = window
        self.person = person
        self.position = position
    }
}

extension LabelledTrick: Decodable {
    private enum CodingKeys: String, CodingKey {
        case window, person
        case position = "at"
    }

    init(from decoder: Decoder) throws {
        if let pair = try? decoder.singleValueContainer().decode([TimeInterval].self) {
            guard let window = Self.window(pair) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "A trick is [start, end], start before end."))
            }
            self.init(window: window)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let window = Self.window(try container.decode([TimeInterval].self, forKey: .window)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .window, in: container, debugDescription: "A trick's window is [start, end], start before end.")
        }
        var position: Position?
        if let point = try container.decodeIfPresent([Float].self, forKey: .position) {
            guard point.count == 2, point.allSatisfy({ (0...1).contains($0) }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .position, in: container, debugDescription: "`at` is [x, y], each a fraction of the frame.")
            }
            position = Position(x: point[0], y: point[1])
        }
        self.init(
            window: window, person: try container.decodeIfPresent(String.self, forKey: .person), position: position)
    }

    private static func window(_ pair: [TimeInterval]) -> ClosedRange<TimeInterval>? {
        guard pair.count == 2, pair[0] < pair[1] else { return nil }
        return pair[0]...pair[1]
    }
}

/// How a video's detected clips line up with its hand-labelled tricks — the measure the
/// detection evaluation (`TrickDetectionEvaluationTests`) reports.
///
/// A trick is caught when one clip covers at least `caughtCoverage` of it, partial when a clip
/// touches it but none covers that much, and missed when no clip touches it. When the label says
/// where the trick's person is, a caught trick also needs one of the clips covering it to frame
/// that point; when none does, the trick is caught by the wrong person instead. A clip touching
/// no labelled trick is a false positive. Coverage is per clip, not the union of clips: a trick
/// split across two clips is not one clip a user can keep.
struct TrickDetectionScore: Equatable {
    enum Outcome: Character {
        case caught = "C"
        case wrongPerson = "W"
        case partial = "P"
        case missed = "M"
    }

    static let caughtCoverage = 0.8

    /// One outcome per labelled trick, in label order.
    let outcomes: [Outcome]
    let falsePositives: Int
    /// Labelled tricks touched by more than one clip: one trick cut into several clips, whether
    /// split in time or framed once per person who was tracked through it.
    let duplicates: Int
    /// Total clip length, buffers included and not clamped to the video's duration.
    let clipSeconds: TimeInterval

    init(clips: [ProcessedClip], tricks: [LabelledTrick]) {
        outcomes = tricks.map { trick in
            let coverages = clips.map {
                Self.overlap($0.window, trick.window) / (trick.window.upperBound - trick.window.lowerBound)
            }
            let catching = zip(clips, coverages).filter { $0.1 >= Self.caughtCoverage - 1e-9 }.map(\.0)
            if !catching.isEmpty {
                guard let position = trick.position else { return .caught }
                return catching.contains { Self.frames($0.cropRect, position) } ? .caught : .wrongPerson
            }
            return coverages.contains { $0 > 0 } ? .partial : .missed
        }
        falsePositives = clips.filter { clip in
            tricks.allSatisfy { Self.overlap(clip.window, $0.window) <= 0 }
        }.count
        duplicates = tricks.filter { trick in
            clips.filter { Self.overlap($0.window, trick.window) > 0 }.count > 1
        }.count
        clipSeconds = clips.reduce(0) { $0 + $1.window.endTime - $1.window.startTime }
    }

    /// Scores windows as full-frame clips against tricks that don't say who did them.
    init(windows: [TrickWindow], tricks: [ClosedRange<TimeInterval>]) {
        let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
        self.init(
            clips: windows.map { ProcessedClip(window: $0, cropRect: fullFrame) },
            tricks: tricks.map { LabelledTrick(window: $0) })
    }

    var caught: Int { count(.caught) }
    var wrongPerson: Int { count(.wrongPerson) }
    var partial: Int { count(.partial) }
    var missed: Int { count(.missed) }

    /// Outcomes in label order, then the false positives and duplicates, e.g. `PPMCW+1fp+0dup`.
    var summary: String {
        String(outcomes.map(\.rawValue)) + "+\(falsePositives)fp+\(duplicates)dup"
    }

    private func count(_ outcome: Outcome) -> Int {
        outcomes.filter { $0 == outcome }.count
    }

    private static func overlap(_ window: TrickWindow, _ trick: ClosedRange<TimeInterval>) -> TimeInterval {
        max(0, min(window.endTime, trick.upperBound) - max(window.startTime, trick.lowerBound))
    }

    private static func frames(_ crop: NormalizedRect, _ position: LabelledTrick.Position) -> Bool {
        (crop.minX...crop.maxX).contains(position.x) && (crop.minY...crop.maxY).contains(position.y)
    }
}

/// Scores summed over several videos.
struct TrickDetectionTally: Equatable {
    var caught = 0
    var wrongPerson = 0
    var partial = 0
    var missed = 0
    var falsePositives = 0
    var duplicates = 0
    var clipSeconds: TimeInterval = 0

    mutating func add(_ score: TrickDetectionScore) {
        caught += score.caught
        wrongPerson += score.wrongPerson
        partial += score.partial
        missed += score.missed
        falsePositives += score.falsePositives
        duplicates += score.duplicates
        clipSeconds += score.clipSeconds
    }

    var summary: String {
        "caught \(caught)  wrong person \(wrongPerson)  partial \(partial)  missed \(missed)  "
            + "false positives \(falsePositives)  duplicates \(duplicates)  clip seconds \(Int(clipSeconds.rounded()))"
    }
}
