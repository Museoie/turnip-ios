import CoreGraphics
import CoreVideo
import Foundation
import TensorFlowLite

/// Wraps a TensorFlowLiteSwift Interpreter for MoveNet MultiPose Lightning (float16), which finds
/// up to six people per frame. See Turnip/Models/README.md for how to obtain the bundled model file.
///
/// An `actor` rather than a class for two reasons: TFLite's `Interpreter` is not thread-safe, so
/// inference calls must be serialized, and actors run on the cooperative pool — never the main
/// thread — so `runInference` (`invoke()` and the output parse, plus the letterbox and RGB repack
/// for the pixel-buffer overload) is structurally kept off the UI thread. Being an actor also
/// makes the model `Sendable`, so it can be captured by the `@Sendable` frame handler in
/// `VideoFrameSampler.sampleFrames`.
///
/// One consequence to keep in mind: `runInference` is synchronous compute (tens of ms per frame)
/// running on a cooperative-pool thread, so it occupies one of the pool's threads (pool width ==
/// core count) for the duration of each call. That is fine for its two callers — a camera session
/// and a Processing run — each of which feeds one frame at a time. If the pipeline runs other async
/// work concurrently with inference, the escape hatch is a custom `SerialExecutor` backed by a
/// utility-QoS queue, or `Task.detached` for the compute — not more actors.
///
/// The model's input size is open: any height and width that are multiples of 32. Each frame is
/// sized to its own aspect (`PoseInputPreparer`), and the interpreter is resized whenever an input
/// arrives at a size it isn't allocated for, which is once per Processing run and once per
/// recording orientation on the camera.
///
/// Construct via `load()`, not `init`: an actor's synchronous `init` runs in the *caller's*
/// context, so calling it from a `@MainActor` `Task` would put the model mmap + tensor allocation
/// on the UI thread. `init` is private to make that impossible to do by accident.
actor MoveNetMultiPoseModel {
    private let interpreter: Interpreter
    /// The input size the interpreter's tensors are allocated for.
    private var allocatedInputSize: CGSize
    /// The preprocess step. Exposed off the actor so the live capture path can reduce frames to
    /// tensors on its own queue and only cross into the actor for `invoke()`; the file path reaches
    /// it through `runInference(on pixelBuffer:)`.
    nonisolated let inputPreparer = PoseInputPreparer(longSide: MoveNetMultiPoseModel.inputLongSide)

    /// The longer side of every input. Not the reference implementation's default of 256: at 256
    /// a far athlete is too few pixels tall to be found at all, and the detection evaluation lost
    /// every trick of the one in its footage.
    static let inputLongSide = 384

    /// The output shape MultiPose reports, in the tensor's `[batch, people, values]` order. The
    /// load-time check that a wrong file fails: a single-pose MoveNet resized to the same input
    /// still loads and allocates, and reports `[1, 1, 17, 3]` here.
    static let expectedOutputShape = [1, DetectedPerson.maximumCount, DetectedPerson.valuesPerPerson]

    /// Loads the bundled model off the main thread. A `nonisolated async` function runs on the
    /// generic executor regardless of the caller's isolation, so the `Interpreter` construction and
    /// `allocateTensors()` inside `init` happen there. This is paid once per camera session and once
    /// per Processing run, not once per launch — each builds a fresh model — so it must not block UI.
    nonisolated static func load() async throws -> MoveNetMultiPoseModel {
        try MoveNetMultiPoseModel()
    }

    /// Throws unless the bundled model's tensor matches `expected`. Pure so it can be tested
    /// without the gitignored `.tflite` — see `MoveNetMultiPoseModelTests`.
    static func validateShape(_ shape: [Int], expected: [Int], named tensorName: String) throws {
        guard shape == expected else {
            throw PoseError.inferenceFailed(
                "Bundled model \(tensorName) is \(shape), expected \(expected) for MoveNet MultiPose "
                    + "Lightning — the file is probably the wrong model. "
                    + "See Turnip/Models/README.md for how to get the right one."
            )
        }
    }

    private init() throws {
        // The .tflite is copied into a "Models/" subfolder of the bundle because project.yml
        // references Turnip/Models as a folder reference, not a group — so look it up there,
        // not at the bundle root.
        guard let modelPath = Bundle.main.path(
            forResource: "movenet_multipose_lightning_float16", ofType: "tflite", inDirectory: "Models"
        ) else {
            throw PoseError.modelNotFound
        }

        // Allocated for a square input up front, so a file that can't take the resize fails here,
        // at load, rather than on the first frame.
        let initialSize = CGSize(width: Self.inputLongSide, height: Self.inputLongSide)
        do {
            interpreter = try Interpreter(modelPath: modelPath)
            try Self.allocate(interpreter, for: initialSize)
        } catch {
            throw PoseError.inferenceFailed(
                "Failed to load MoveNet MultiPose model: \(error.localizedDescription)")
        }
        allocatedInputSize = initialSize

        let inputTensor = try interpreter.input(at: 0)
        guard inputTensor.dataType == .uInt8 else {
            throw PoseError.inferenceFailed(
                "Model input wants \(inputTensor.dataType), the frame packing writes uInt8"
            )
        }
        // The output's shape follows the input's, so TFLite leaves it unreadable until the model
        // has run: one blank frame, so the check below happens at load rather than on a real one.
        try interpreter.copy(Data(count: inputTensor.data.count), toInputAt: 0)
        try interpreter.invoke()
        let outputTensor = try interpreter.output(at: 0)
        try Self.validateShape(outputTensor.shape.dimensions, expected: Self.expectedOutputShape, named: "output")
    }

    /// Preprocesses on the actor, then infers. The file-based caller (`ProcessingPipeline`) holds a
    /// decoded pixel buffer and nothing else is contending for the actor, so paying the letterbox
    /// here costs it nothing over doing it itself.
    func runInference(on pixelBuffer: CVPixelBuffer) throws -> [DetectedPerson] {
        try runInference(on: inputPreparer.prepare(pixelBuffer))
    }

    /// The people come back frame-normalized: the letterbox inversion happens here, at the
    /// producer, because every consumer reads `PoseKeypoint.x/y` as frame fractions and nothing
    /// in the type system distinguishes converted keypoints from unconverted ones.
    func runInference(on input: PoseModelInput) throws -> [DetectedPerson] {
        if input.mapping.inputSize != allocatedInputSize {
            try Self.allocate(interpreter, for: input.mapping.inputSize)
            allocatedInputSize = input.mapping.inputSize
        }
        try interpreter.copy(input.tensor, toInputAt: 0)
        try interpreter.invoke()
        let values = Self.dequantize(try interpreter.output(at: 0))
        return try DetectedPerson.parse(from: values).map(input.mapping.frameNormalized(person:))
    }

    /// The float16 build stores its weights as float16 but takes uint8 in and gives float32 out
    /// (`[1, 6, 56]`) — verified against the real artifact (hash recorded in
    /// `Turnip/Models/README.md`). The uint8 branch is a defensive path for a future model whose
    /// output tensor is quantized, not the path the bundled model takes.
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

    private static func allocate(_ interpreter: Interpreter, for size: CGSize) throws {
        try interpreter.resizeInput(
            at: 0,
            to: Tensor.Shape([1, Int(size.height), Int(size.width), FramePreprocessor.channelCount]))
        try interpreter.allocateTensors()
    }
}
