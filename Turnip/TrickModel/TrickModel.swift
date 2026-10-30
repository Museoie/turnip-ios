import CoreML
import Foundation

enum TrickModelError: Error, Equatable {
    /// The artifact unpacked, but held no `TrickDetector.mlpackage`.
    case packageMissing
    /// The model doesn't describe its classes and window grid, or lacks the input or output the
    /// contract names.
    case descriptorMissing
    /// The model's output doesn't have the shape the input and the descriptor call for.
    case unexpectedOutput
}

/// What one run of the model over one person's pose returns.
struct TrickModelOutput: Sendable {
    /// `window_probs` decoded into segments (`MODEL_CONTRACT.md` §3.2.1), before the client's
    /// postprocessing.
    let segments: [TrickSegment]
    /// `window_embeddings`, one row per window on the descriptor's grid (§3.2.2); `nil` for a
    /// model without them.
    let embeddings: [[Float]]?
}

/// The trick-detection model (`MODEL_CONTRACT.md` §3), compiled and loaded from the artifact an
/// OTA update staged: a classifier over windows of the canonical 10 Hz pose.
///
/// The classes and window grid come from the model's own metadata, which the export writes, so
/// the model describes itself and the loader needs nothing from the manifest but its version.
///
/// `@unchecked Sendable` because `MLModel` isn't marked `Sendable`: every prediction goes through
/// `lock`, so one loaded model can serve every analysis of the session.
final class TrickModel: @unchecked Sendable {
    static let packageName = "TrickDetector.mlpackage"
    static let inputName = "pose"
    static let probabilitiesOutputName = "window_probs"
    static let embeddingsOutputName = "window_embeddings"

    /// The model's release, the manifest's `version`: what a clip it proposed records as its
    /// proposing model.
    let version: String
    let descriptor: TrickModelDescriptor
    let hasEmbeddings: Bool
    private let model: MLModel
    private let lock = NSLock()

    init(model: MLModel, version: String) throws {
        let description = model.modelDescription
        let metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let classesJSON = metadata["turnip.classes"],
              let classes = try? JSONDecoder().decode([String].self, from: Data(classesJSON.utf8)),
              let windowFrames = metadata["turnip.window_frames"].flatMap(Int.init),
              let windowStride = metadata["turnip.window_stride"].flatMap(Int.init),
              windowFrames >= 2, windowStride >= 1, Set(classes).count == classes.count,
              description.inputDescriptionsByName[Self.inputName] != nil,
              description.outputDescriptionsByName[Self.probabilitiesOutputName] != nil
        else { throw TrickModelError.descriptorMissing }
        let descriptor = TrickModelDescriptor(classes: classes, windowFrames: windowFrames, windowStride: windowStride)
        guard classes.contains(descriptor.backgroundClass) else { throw TrickModelError.descriptorMissing }
        self.model = model
        self.version = version
        self.descriptor = descriptor
        hasEmbeddings = description.outputDescriptionsByName[Self.embeddingsOutputName] != nil
    }

    /// Unpacks the staged artifact into a scratch folder, compiles the package it holds, and loads
    /// the compiled model. The pipeline ships the package rather than a compiled model because
    /// compiling needs Apple's tools (`MODEL_CONTRACT.md` §2). The compiled model stays where Core
    /// ML put it, in the temporary directory, for as long as the session uses it.
    ///
    /// The model runs on the CPU: it is a few kilobytes of arithmetic over one short sequence per
    /// analysis, and its standardization runs in fp32, which the Neural Engine would not keep.
    static func load(artifact: URL, version: String) async throws -> TrickModel {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrickModel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try StoredZipArchive.extract(Data(contentsOf: artifact), to: scratch)
        let package = scratch.appendingPathComponent(packageName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: package.path) else { throw TrickModelError.packageMissing }
        let compiled = try await MLModel.compileModel(at: package)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try TrickModel(
            model: try await MLModel.load(contentsOf: compiled, configuration: configuration), version: version)
    }

    /// Runs the model once over `input`. `nil` when the input is shorter than one window: there is
    /// nothing to classify, and the model refuses a sequence that short.
    func run(_ input: TrickModelInput) throws -> TrickModelOutput? {
        let windows = descriptor.windowCount(frameCount: input.frameCount)
        guard windows > 0 else { return nil }
        let channels = TrickModelInput.channels
        let pose = try MLMultiArray(
            shape: [NSNumber(value: input.frameCount), NSNumber(value: channels)], dataType: .float32)
        pose.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            for frame in 0..<input.frameCount {
                for channel in 0..<channels {
                    buffer[frame * strides[0] + channel * strides[1]] = input.values[frame * channels + channel]
                }
            }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(multiArray: pose)])
        let output = try lock.withLock { try model.prediction(from: features) }

        guard let probabilities = output.featureValue(for: Self.probabilitiesOutputName)?.multiArrayValue else {
            throw TrickModelError.unexpectedOutput
        }
        let rows = try Self.rows(of: probabilities, count: windows, width: descriptor.classes.count)
        var embeddings: [[Float]]?
        if hasEmbeddings {
            guard let values = output.featureValue(for: Self.embeddingsOutputName)?.multiArrayValue else {
                throw TrickModelError.unexpectedOutput
            }
            embeddings = try Self.rows(of: values, count: windows, width: nil)
        }
        return TrickModelOutput(segments: descriptor.segments(windowProbabilities: rows), embeddings: embeddings)
    }

    /// A two-dimensional output as rows, checked against the row count and, when given, the width
    /// it should have.
    private static func rows(of array: MLMultiArray, count: Int, width: Int?) throws -> [[Float]] {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 2, shape[0] == count, width.map({ $0 == shape[1] }) ?? true else {
            throw TrickModelError.unexpectedOutput
        }
        let strides = array.strides.map(\.intValue)
        guard array.dataType == .float32 else {
            return (0..<shape[0]).map { row in
                (0..<shape[1]).map { array[[NSNumber(value: row), NSNumber(value: $0)]].floatValue }
            }
        }
        return array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            (0..<shape[0]).map { row in
                (0..<shape[1]).map { buffer[row * strides[0] + $0 * strides[1]] }
            }
        }
    }
}
