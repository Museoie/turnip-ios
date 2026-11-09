import Accelerate
import Foundation

/// A segment the central model scores inside the band the keep layer decides
/// (`docs/PERSONALIZATION_DESIGN.md` §4.3, `MODEL_CONTRACT.md` §3.3 step 1), as decoded from
/// `window_probs` before NMS and merging: its canonical frames, end exclusive, its score, and its
/// embedding by §4.1's rule.
struct BandSegment: Codable, Hashable, Sendable {
    let startFrame: Int
    let endFrame: Int
    let score: Float
    /// Unit length.
    let vector: [Float]
}

extension WindowEmbeddings {
    /// Every band segment of the run. Analysis, the save and the rebuild all read a run's segments
    /// through this, so what the layer learns from is what it later decides.
    var bandSegments: [BandSegment] {
        descriptor.segments(windowProbabilities: probabilities).compactMap { segment in
            guard TrickProposalRules.personalBand.contains(segment.score),
                  let vector = embedding(fromFrame: segment.startFrame, to: segment.endFrame)
            else { return nil }
            return BandSegment(
                startFrame: segment.startFrame, endFrame: segment.endFrame, score: segment.score, vector: vector)
        }
    }

    /// `layer`'s decision over this run's segments, `nil` when there is none to make: no layer, or
    /// one fit under another model version, which the analysis's own load may have activated.
    func keepDecision(by layer: PersonalKeepLayer?) -> ((TrickSegment) -> Bool?)? {
        guard let layer, layer.modelVersion == modelVersion else { return nil }
        return { segment in
            embedding(fromFrame: segment.startFrame, to: segment.endFrame)
                .flatMap { layer.keeps(score: segment.score, vector: $0) }
        }
    }
}

/// The keep layer's parameters: `p(keep) = σ(scale · logit(s) + offset + weights · e)`, where `s` is
/// a segment's central score and `e` its embedding (`docs/PERSONALIZATION_DESIGN.md` §4.3).
struct KeepLayerParameters: Equatable, Sendable {
    var scale: Double
    var offset: Double
    var weights: [Double]

    /// The central model itself, `p = s`: what the fit starts from and is pulled back toward.
    static func prior(width: Int) -> KeepLayerParameters {
        KeepLayerParameters(scale: 1, offset: 0, weights: Array(repeating: 0, count: width))
    }

    /// A score's logit, the score clamped to `[0.01, 0.99]` so it stays finite.
    static func logit(_ score: Float) -> Double {
        let clamped = min(max(Double(score), 0.01), 0.99)
        return log(clamped / (1 - clamped))
    }

    /// The logit of `p(keep)`; `nil` for an embedding of another width than the layer's.
    func logit(score: Float, vector: [Float]) -> Double? {
        guard vector.count == weights.count else { return nil }
        var total = scale * Self.logit(score) + offset
        for (weight, value) in zip(weights, vector) {
            total += weight * Double(value)
        }
        return total
    }

    /// `θ`, in the order the fit's design matrix lays its columns out.
    fileprivate var theta: [Double] { [scale, offset] + weights }

    fileprivate init(theta: [Double]) {
        self.init(scale: theta[0], offset: theta[1], weights: Array(theta.dropFirst(2)))
    }

    init(scale: Double, offset: Double, weights: [Double]) {
        self.scale = scale
        self.offset = offset
        self.weights = weights
    }
}

/// The keep layer as analysis reads it, once it has passed its gate (§5): it decides whether a
/// segment scoring inside `TrickProposalRules.personalBand` is proposed. It is fit under one model
/// version and means nothing under another.
struct PersonalKeepLayer: Equatable, Sendable {
    /// λ in the fit's penalty `λ‖θ − θ₀‖²`: moving any parameter by one costs one nat, the log loss
    /// of one example the layer gives `p ≈ 0.37` for its own label, so a few examples can't pull
    /// the layer far from the central model. *(Judgment call, §11.)*
    static let penalty: Double = 1

    let modelVersion: String
    let parameters: KeepLayerParameters

    /// Whether a segment in the band is proposed, `p ≥ 0.5`; `nil` when its embedding doesn't fit
    /// the layer, and the central rule decides.
    func keeps(score: Float, vector: [Float]) -> Bool? {
        parameters.logit(score: score, vector: vector).map { $0 >= 0 }
    }
}

/// Fits the keep layer by Newton's method on the log loss plus the penalty toward the central
/// model (`docs/PERSONALIZATION_DESIGN.md` §4.3). Each step solves one `(D + 2) × (D + 2)` system
/// with Accelerate's LAPACK; the penalty keeps that system positive definite, so a Cholesky solve
/// always applies.
enum KeepLayerFit {
    static let maximumIterations = 50

    /// The parameters for `examples`, whose embeddings are `width` long; an example of another
    /// width is left out. With no example, the prior.
    static func fit(
        _ examples: [KeepExample], width: Int, penalty: Double = PersonalKeepLayer.penalty
    ) -> KeepLayerParameters {
        let usable = examples.filter { $0.vector.count == width }
        let prior = KeepLayerParameters.prior(width: width)
        guard !usable.isEmpty else { return prior }
        let problem = KeepLayerProblem(usable, prior: prior.theta, penalty: penalty)
        var theta = prior.theta
        var objective = problem.objective(at: theta)
        for _ in 0..<maximumIterations {
            guard let step = problem.newtonStep(at: theta) else { break }
            // Halving the step until the objective doesn't rise keeps a separable set, where the
            // full step can overshoot, converging.
            var length = 1.0
            var moved = false
            while length > 1e-8 {
                let candidate = zip(theta, step).map { $0 - length * $1 }
                let value = problem.objective(at: candidate)
                if value <= objective {
                    let largestMove = step.map { abs($0) * length }.max() ?? 0
                    theta = candidate
                    moved = largestMove > 1e-10 && objective - value > 1e-12 * (1 + abs(value))
                    objective = value
                    break
                }
                length /= 2
            }
            guard moved else { break }
        }
        return KeepLayerParameters(theta: theta)
    }

    /// The mean log loss of `parameters` over `examples`, the gate's measure (§5). Worked from the
    /// logit, so a confident example can't make it infinite.
    static func logLoss(of parameters: KeepLayerParameters, over examples: [KeepExample]) -> Double {
        let losses = examples.compactMap { example in
            parameters.logit(score: example.score, vector: example.vector).map {
                softplus($0) - (example.isKept ? $0 : 0)
            }
        }
        return losses.isEmpty ? 0 : losses.reduce(0, +) / Double(losses.count)
    }

    /// `log(1 + eᶻ)`, without overflow either way.
    fileprivate static func softplus(_ margin: Double) -> Double {
        max(margin, 0) + log1p(exp(-abs(margin)))
    }

    fileprivate static func sigmoid(_ margin: Double) -> Double {
        1 / (1 + exp(-margin))
    }
}

/// The fit's data: one row per example, `[logit(s), 1, e…]`, and its label.
private struct KeepLayerProblem {
    let design: [Double]
    let labels: [Double]
    let rows: Int
    let columns: Int
    let prior: [Double]
    let penalty: Double

    init(_ examples: [KeepExample], prior: [Double], penalty: Double) {
        rows = examples.count
        columns = prior.count
        var design = [Double](repeating: 0, count: rows * columns)
        for (row, example) in examples.enumerated() {
            design[row * columns] = KeepLayerParameters.logit(example.score)
            design[row * columns + 1] = 1
            for (column, value) in example.vector.enumerated() {
                design[row * columns + 2 + column] = Double(value)
            }
        }
        self.design = design
        labels = examples.map { $0.isKept ? 1 : 0 }
        self.prior = prior
        self.penalty = penalty
    }

    /// `Xθ`.
    private func margins(at theta: [Double]) -> [Double] {
        var margins = [Double](repeating: 0, count: rows)
        cblas_dgemv(
            CblasRowMajor, CblasNoTrans, Int32(rows), Int32(columns), 1, design, Int32(columns), theta, 1, 0,
            &margins, 1)
        return margins
    }

    /// The summed log loss plus `λ‖θ − θ₀‖²`.
    func objective(at theta: [Double]) -> Double {
        let loss = zip(margins(at: theta), labels).reduce(0) { total, pair in
            total + KeepLayerFit.softplus(pair.0) - pair.1 * pair.0
        }
        let distance = zip(theta, prior).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        return loss + penalty * distance
    }

    /// `H⁻¹g` at `theta`: the gradient `Xᵀ(p − y) + 2λ(θ − θ₀)` through the Hessian
    /// `Xᵀ diag(p(1 − p)) X + 2λI`. `nil` when LAPACK can't solve it.
    func newtonStep(at theta: [Double]) -> [Double]? {
        let margins = margins(at: theta)
        var residuals = [Double](repeating: 0, count: rows)
        var weighted = design
        for row in 0..<rows {
            let probability = KeepLayerFit.sigmoid(margins[row])
            residuals[row] = probability - labels[row]
            let root = (probability * (1 - probability)).squareRoot()
            for column in 0..<columns {
                weighted[row * columns + column] *= root
            }
        }
        var gradient = zip(theta, prior).map { 2 * penalty * ($0 - $1) }
        cblas_dgemv(
            CblasRowMajor, CblasTrans, Int32(rows), Int32(columns), 1, design, Int32(columns), residuals, 1, 1,
            &gradient, 1)
        var hessian = [Double](repeating: 0, count: columns * columns)
        cblas_dsyrk(
            CblasRowMajor, CblasUpper, CblasTrans, Int32(columns), Int32(rows), 1, weighted, Int32(columns), 0,
            &hessian, Int32(columns))
        for index in 0..<columns {
            hessian[index * columns + index] += 2 * penalty
        }
        return Self.solve(hessian, gradient, size: columns)
    }

    /// Solves `A x = b` for a symmetric positive definite `A` by Cholesky (`dposv`). `A` holds its
    /// upper triangle row-major, which LAPACK's column-major order reads as the lower one.
    private static func solve(_ matrix: [Double], _ vector: [Double], size: Int) -> [Double]? {
        var matrix = matrix
        var solution = vector
        var triangle = CChar(UInt8(ascii: "L"))
        var order = __CLPK_integer(size)
        var rightHandSides = __CLPK_integer(1)
        var matrixStride = __CLPK_integer(size)
        var solutionStride = __CLPK_integer(size)
        var info = __CLPK_integer(0)
        dposv_(&triangle, &order, &rightHandSides, &matrix, &matrixStride, &solution, &solutionStride, &info)
        guard info == 0, solution.allSatisfy(\.isFinite) else { return nil }
        return solution
    }
}
