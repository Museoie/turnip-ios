import CoreVideo
import Foundation
import TensorFlowLite

/// Wraps a TensorFlowLiteSwift Interpreter for MoveNet Thunder (singlepose, int8).
/// See Turnip/Models/README.md for how to obtain the bundled model file.
///
/// An `actor` rather than a class for two reasons: TFLite's `Interpreter` is not thread-safe, so
/// inference calls must be serialized, and actors run on the cooperative pool — never the main
/// thread — so `runInference` (`invoke()` and dequantize, plus the letterbox and RGB repack for
/// the pixel-buffer overload) is structurally kept off the UI thread. Being an actor also makes
/// the model `Sendable`, so it can be captured by the `@Sendable` frame handler in
/// `VideoFrameSampler.sampleFrames`.
///
/// One consequence to keep in mind: `runInference` is synchronous compute (tens of ms per frame)
/// running on a cooperative-pool thread, so it occupies one of the pool's threads (pool width ==
/// core count) for the duration of each call. That is fine for its two callers — a camera session
/// and a Processing run — each of which feeds one frame at a time. If the pipeline runs other async
/// work concurrently with inference, the escape hatch is a custom `SerialExecutor` backed by a
/// utility-QoS queue, or `Task.detached` for the compute — not more actors.
///
/// Construct via `load()`, not `init`: an actor's synchronous `init` runs in the *caller's*
/// context, so calling it from a `@MainActor` `Task` would put the model mmap + tensor allocation
/// on the UI thread. `init` is private to make that impossible to do by accident.
actor MoveNetThunderModel {
    private let interpreter: Interpreter
    /// The preprocess step, sized from the bundled model's input tensor. Exposed off the actor so
    /// the live capture path can reduce frames to tensors on its own queue and only cross into the
    /// actor for `invoke()`; the file path reaches it through `runInference(on pixelBuffer:)`.
    nonisolated let inputPreparer: PoseInputPreparer

    /// Loads the bundled model off the main thread. A `nonisolated async` function runs on the
    /// generic executor regardless of the caller's isolation, so the `Interpreter` construction and
    /// `allocateTensors()` inside `init` happen there. This is paid once per camera session and once
    /// per Processing run, not once per launch — each builds a fresh model — so it must not block UI.
    nonisolated static func load() async throws -> MoveNetThunderModel {
        try MoveNetThunderModel()
    }

    /// The input shape the MoveNet Thunder singlepose int8 variant reports, in the tensor's
    /// `[batch, height, width, channels]` order. A wrong variant — Lightning is 192x192 — still
    /// loads, allocates tensors, and emits output the keypoint parser accepts, so the only symptom
    /// of a wrong file would be silently worse keypoints. Reject it here, on the failure path.
    static let expectedInputShape = [1, 256, 256, 3]

    /// The output shape the MoveNet Thunder singlepose int8 variant reports, in the tensor's
    /// `[batch, persons, keypoints, coords]` order. Checked for the same reason as the input
    /// shape: a wrong variant's output is still parseable (the parser only counts 51 floats), so
    /// without this a wrong file would again surface only as silently worse keypoints.
    static let expectedOutputShape = [1, 1, 17, 3]

    /// Throws unless the bundled model's tensor matches `expected`. Checked at load so a
    /// wrong variant fails with a visible error instead of silently worse keypoints: TFLite
    /// still loads and allocates a wrong-variant file, and emits output the keypoint parser
    /// accepts. Pure so it can be tested without the gitignored `.tflite` — see
    /// `MoveNetThunderModelTests`.
    static func validateShape(_ shape: [Int], expected: [Int], named tensorName: String) throws {
        guard shape == expected else {
            throw PoseError.inferenceFailed(
                "Bundled model \(tensorName) is \(shape), expected \(expected) for MoveNet Thunder "
                    + "singlepose int8 — the file is probably the wrong variant. "
                    + "See Turnip/Models/README.md for how to get the right one."
            )
        }
    }

    private init() throws {
        // The .tflite is copied into a "Models/" subfolder of the bundle because project.yml
        // references Turnip/Models as a folder reference, not a group — so look it up there,
        // not at the bundle root.
        guard let modelPath = Bundle.main.path(
            forResource: "movenet_thunder_int8", ofType: "tflite", inDirectory: "Models"
        ) else {
            throw PoseError.modelNotFound
        }

        do {
            interpreter = try Interpreter(modelPath: modelPath)
            try interpreter.allocateTensors()
        } catch {
            throw PoseError.inferenceFailed("Failed to load MoveNet Thunder model: \(error.localizedDescription)")
        }

        // Read the tensors at runtime rather than assuming 256x256 uint8, so the checks below
        // run against the actual bundled file. A future model swap (e.g. escalating to BlazePose
        // per the design doc) means a new wrapper type with its own expected shape — this type's
        // contract is specifically the Thunder singlepose int8 variant.
        let inputTensor = try interpreter.input(at: 0)
        guard inputTensor.dataType == .uInt8 else {
            throw PoseError.inferenceFailed(
                "Model input wants \(inputTensor.dataType), the frame packing writes uInt8"
            )
        }
        try Self.validateShape(inputTensor.shape.dimensions, expected: Self.expectedInputShape, named: "input")
        let outputTensor = try interpreter.output(at: 0)
        try Self.validateShape(outputTensor.shape.dimensions, expected: Self.expectedOutputShape, named: "output")
        inputPreparer = PoseInputPreparer(
            preprocessor: try FramePreprocessor(inputShape: inputTensor.shape.dimensions))
    }

    /// Preprocesses on the actor, then infers. The file-based caller (`ProcessingPipeline`) holds a
    /// decoded pixel buffer and nothing else is contending for the actor, so paying the letterbox
    /// here costs it nothing over doing it itself.
    func runInference(on pixelBuffer: CVPixelBuffer) throws -> [PoseKeypoint] {
        try runInference(on: inputPreparer.prepare(pixelBuffer))
    }

    /// The keypoints come back frame-normalized: the letterbox inversion happens here, at the
    /// producer, because every consumer reads `PoseKeypoint.x/y` as frame fractions and nothing
    /// in the type system distinguishes converted keypoints from unconverted ones.
    func runInference(on input: PoseModelInput) throws -> [PoseKeypoint] {
        try interpreter.copy(input.tensor, toInputAt: 0)
        try interpreter.invoke()
        let outputTensor = try interpreter.output(at: 0)
        let values = Self.dequantize(outputTensor)
        return input.mapping.frameNormalized(keypoints: try PoseKeypoint.parse(from: values))
    }

    /// The int8 build quantizes the weights and the input, but its output tensor is
    /// float32 ([1, 1, 17, 3]) — verified against the real artifact (hash recorded in
    /// `Turnip/Models/README.md`). The uint8 branch is a defensive path for a future
    /// model whose output tensor is quantized, not the path the bundled model takes.
    private static func dequantize(_ tensor: Tensor) -> [Float] {
        if tensor.dataType == .uInt8, let quantization = tensor.quantizationParameters {
            return TensorDequantizer.floats(
                fromUInt8: tensor.data,
                scale: quantization.scale,
                zeroPoint: quantization.zeroPoint
            )
        }

        return TensorDequantizer.floats(fromFloat32: tensor.data)
    }
}
