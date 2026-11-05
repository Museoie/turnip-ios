import Foundation

/// What the personal layer keeps of one clip under one model (`docs/PERSONALIZATION_DESIGN.md`
/// §4.1). Comparable only with embeddings of the same `modelVersion`.
struct ClipEmbedding: Codable, Hashable, Sendable {
    let modelVersion: String
    /// Unit length, so a dot product is a cosine similarity.
    let vector: [Float]
    /// Every name the central model offers for the clip, surest first, a combo's classes split
    /// into their names: the gate's central side (§5).
    let centralNames: [String]
}

extension WindowEmbeddings {
    /// A clip's embedding by `MODEL_CONTRACT.md` §3.5's rule: the mean of the rows whose windows
    /// lie wholly inside the clip's, or the single most-overlapping row when none do,
    /// L2-normalized. `nil` when there is no row, or its values are all zero.
    func clipEmbedding(of window: TrickWindow) -> ClipEmbedding? {
        let indices = rowIndices(for: window)
        guard let width = indices.first.map({ rows[$0].count }) else { return nil }
        var sum = [Float](repeating: 0, count: width)
        for index in indices {
            for (column, value) in rows[index].enumerated() {
                sum[column] += value
            }
        }
        guard let vector = sum.unitLength else { return nil }
        return ClipEmbedding(modelVersion: modelVersion, vector: vector, centralNames: centralNames(over: indices))
    }

    /// The rows §3.5 reads for `window`.
    func rowIndices(for window: TrickWindow) -> [Int] {
        guard !rows.isEmpty else { return [] }
        let stride = descriptor.windowStride, width = descriptor.windowFrames
        let frames = ContributionPose.canonicalFrames(of: window, frameCount: (rows.count - 1) * stride + width)
        let inside = rows.indices.filter { frames.start <= $0 * stride && $0 * stride + width <= frames.end }
        guard inside.isEmpty else { return inside }
        func overlap(_ row: Int) -> Int {
            min(frames.end, row * stride + width) - max(frames.start, row * stride)
        }
        return rows.indices.max { overlap($0) < overlap($1) }.map { [$0] } ?? []
    }

    /// Each name's score over `indices`: its class's mean probability, the highest of them for a
    /// name in several classes, the way a combo shares its class with its names. Every clip gets a
    /// ranking from this, a "+" clip too, where a segment would give one class's names at most and
    /// leave the gate's central side short of the three names §5 cuts it at.
    private func centralNames(over indices: [Int]) -> [String] {
        var scores: [String: Float] = [:]
        var names: [String] = []
        for (column, label) in descriptor.classes.enumerated() where label != descriptor.backgroundClass {
            let mean = indices.reduce(Float(0)) { $0 + probabilities[$1][column] } / Float(indices.count)
            for name in label.split(separator: descriptor.comboSeparator).map(String.init) {
                if scores[name] == nil { names.append(name) }
                scores[name] = max(scores[name] ?? 0, mean)
            }
        }
        return names.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = scores[lhs.element] ?? 0, rhsScore = scores[rhs.element] ?? 0
                return lhsScore != rhsScore ? lhsScore > rhsScore : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

extension Array where Element == Float {
    /// Scaled to length one; `nil` for a vector of zeros, which has no direction.
    var unitLength: [Float]? {
        let length = reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? map { $0 / length } : nil
    }

    func dot(_ other: [Float]) -> Float {
        zip(self, other).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}
