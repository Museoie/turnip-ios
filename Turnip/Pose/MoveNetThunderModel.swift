import CoreImage
import CoreVideo
import Foundation
import TensorFlowLite

/// Wraps a TensorFlowLiteSwift Interpreter for MoveNet Thunder (singlepose, int8).
/// See Turnip/Models/README.md for how to obtain the bundled model file.
///
/// An `actor` rather than a class for two reasons: TFLite's `Interpreter` is not thread-safe, so
/// inference calls must be serialized, and actors run on the cooperative pool — never the main
/// thread — so `runInference` (CIContext resize, BGRA→RGB repack, `invoke()`, dequantize) is
/// structurally kept off the UI thread. Being an actor also makes the model `Sendable`, so it can
/// be captured by the `@Sendable` frame handler in `VideoFrameSampler.sampleFrames`.
///
/// One consequence to keep in mind: `runInference` is synchronous compute (tens of ms per frame)
/// running on a cooperative-pool thread, so it occupies one of the pool's threads (pool width ==
/// core count) for the duration of each call. That is fine for the diagnostic, where there is
/// exactly one caller and the sampler serializes frames anyway. If the pipeline later runs other
/// async work concurrently with inference, the escape hatch is a custom `SerialExecutor` backed by
/// a utility-QoS queue, or `Task.detached` for the compute — not more actors.
///
/// Construct via `load()`, not `init`: an actor's synchronous `init` runs in the *caller's*
/// context, so calling it from a `@MainActor` `Task` would put the model mmap + tensor allocation
/// on the UI thread. `init` is private to make that impossible to do by accident.
actor MoveNetThunderModel {
    private let interpreter: Interpreter
    private let preprocessor: FramePreprocessor
    private let ciContext = CIContext()

    /// The version of the model shipped in the app bundle: the Kaggle
    /// `singlepose-thunder-tflite-int8` instance 1 (see
    /// Turnip/Models/README.md for provenance). The OTA loader uses it as the
    /// floor — a staged file shadows the bundled one only when its manifest
    /// version is strictly newer, so an older staged file can't pin the app
    /// to a worse model, and a newer app build's bundled model isn't shadowed
    /// by a stale OTA file.
    static let bundledModelVersion = ModelVersion("1")

    /// Loads the bundled model off the main thread. A `nonisolated async` function runs on the
    /// generic executor regardless of the caller's isolation, so the `Interpreter` construction and
    /// `allocateTensors()` inside `init` happen there. This is paid once per diagnostic run, not
    /// once per launch — every "Run diagnostic" tap builds a fresh model — so it must not block UI.
    ///
    /// OTA wiring (issue #96): a staged model shadows the bundled one only when its manifest
    /// version is newer than `bundledModelVersion`. A staged file that fails to load or to
    /// validate as the Thunder int8 variant falls back to the bundled model rather than leaving
    /// the app without pose estimation. A staged file that fails the *variant* check is evicted
    /// from the store first, so the next update check re-stages cleanly instead of repeating the
    /// wasted staged load on every run. Conversely, a *missing* bundled model (e.g. the #123
    /// TestFlight failure) no longer aborts loading before the staged file is consulted: the
    /// candidate is resolved through the store first and the bundled path is only required when
    /// the candidate *is* the bundled one — `modelNotFound` is thrown only when neither source
    /// yields a loadable model.
    nonisolated static func load() async throws -> MoveNetThunderModel {
        let bundledPath: String?
        do {
            bundledPath = try Self.bundledModelPath()
        } catch PoseError.modelNotFound {
            // The bundled model is missing, but a staged OTA file may still
            // rescue loading — fall through to the staged path instead of
            // aborting here.
            bundledPath = nil
        }
        let store = ModelUpdateStore.production
        let candidate = resolveModelPath(
            bundledPath: bundledPath,
            stagedVersion: store?.activeVersion(),
            stagedPath: store?.activeModelURL()?.path)
        guard let candidate else {
            throw PoseError.modelNotFound
        }
        do {
            return try MoveNetThunderModel(modelPath: candidate)
        } catch {
            // When the staged file fails the variant check (checksum passed but the bytes are
            // the wrong model), evict the staged record before falling back: the update service
            // short-circuits re-downloads while a record with an older-or-equal version exists,
            // so without eviction every diagnostic run would repeat this wasted staged load
            // until a newer manifest ships. Only content/shape failures evict — a transient
            // failure (e.g. an allocateTensors OOM) must not drop a good staged model.
            if case PoseError.wrongModelVariant = error, candidate != bundledPath {
                store?.clearActive()
            }
            // The staged file failed: retry with the bundled model before
            // giving up. When the candidate already *is* the bundled model —
            // or there is no bundled model to fall back to — there is nothing
            // left to try, so rethrow the load failure. (`throw error` rather
            // than bare `throw`: a bare `throw` doesn't compile nested inside
            // this `guard-else`.)
            guard let bundledPath, candidate != bundledPath else { throw error }
            return try MoveNetThunderModel(modelPath: bundledPath)
        }
    }

    /// Picks the model file to load: the staged OTA file only when its
    /// manifest version is well-formed and strictly newer than the bundled
    /// one — never merely because a staged file exists. The well-formedness
    /// gate defends the version-floor comparison: a malformed stored version
    /// (e.g. a store record written before the manifest-validation gate
    /// existed) would otherwise fall through `ModelVersion.<`'s lexicographic
    /// fallback and could pin the loader to a staged file the floor was meant
    /// to reject. A staged version with no bytes on disk
    /// is treated the same as no staged model, so metadata-without-bytes can
    /// never redirect the loader at a file that isn't there.
    ///
    /// `bundledPath` is nil when the bundled model is missing from the app
    /// bundle: the staged model is still consulted, so a missing bundled model
    /// doesn't abort loading before the staged file is tried. Returns nil when
    /// neither source yields a candidate, in which case the loader reports
    /// `modelNotFound`.
    ///
    /// Pure over its inputs so the version-floor rule is unit-testable without
    /// touching the real Application Support directory.
    static func resolveModelPath(
        bundledPath: String?,
        stagedVersion: ModelVersion?,
        stagedPath: String?
    ) -> String? {
        if let stagedVersion, let stagedPath,
            stagedVersion.isWellFormed, stagedVersion > bundledModelVersion {
            return stagedPath
        }
        return bundledPath
    }

    /// The bundled model's path. The .tflite is copied into a "Models/" subfolder of the bundle because project.yml
    /// references Turnip/Models as a folder reference, not a group — so look it up there,
    /// not at the bundle root.
    private static func bundledModelPath() throws -> String {
        guard let modelPath = Bundle.main.path(
            forResource: "movenet_thunder_int8", ofType: "tflite",
            inDirectory: "Models"
        ) else {
            throw PoseError.modelNotFound
        }
        return modelPath
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
    /// accepts. Throws `PoseError.wrongModelVariant` (not `inferenceFailed`) so `load()` can
    /// evict a bad staged record without dropping a good one on a transient load failure.
    /// Pure so it can be tested without the gitignored `.tflite` — see
    /// `MoveNetThunderModelTests`.
    static func validateShape(_ shape: [Int], expected: [Int], named tensorName: String) throws {
        guard shape == expected else {
            throw PoseError.wrongModelVariant(
                "Bundled model \(tensorName) is \(shape), expected \(expected) for MoveNet Thunder "
                    + "singlepose int8 — the file is probably the wrong variant. "
                    + "See Turnip/Models/README.md for how to get the right one."
            )
        }
    }

    private init(modelPath: String) throws {
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
        preprocessor = try FramePreprocessor(inputShape: inputTensor.shape.dimensions)
    }

    /// The keypoints come back frame-normalized: the letterbox inversion happens here, at the
    /// producer, because every consumer reads `PoseKeypoint.x/y` as frame fractions and nothing
    /// in the type system distinguishes converted keypoints from unconverted ones.
    func runInference(on pixelBuffer: CVPixelBuffer) throws -> [PoseKeypoint] {
        let (inputData, mapping) = try resizedRGBData(from: pixelBuffer)
        try interpreter.copy(inputData, toInputAt: 0)
        try interpreter.invoke()
        let outputTensor = try interpreter.output(at: 0)
        let values = Self.dequantize(outputTensor)
        return mapping.frameNormalized(keypoints: try PoseKeypoint.parse(from: values))
    }

    /// Letterboxes the source frame into the model's input size (uniform scale, centered) and
    /// packs it as interleaved RGB uint8, matching MoveNet Thunder's expected [1, height, width, 3]
    /// input tensor. Returns the packing together with the geometry that placed it, so keypoints
    /// can be mapped back to the source frame.
    private func resizedRGBData(from pixelBuffer: CVPixelBuffer) throws -> (
        data: Data, mapping: LetterboxMapping
    ) {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let (transform, mapping) = try preprocessor.letterboxGeometry(forSourceExtent: sourceImage.extent)
        let outputBuffer = try preprocessor.makeTargetBuffer()
        ciContext.render(sourceImage.transformed(by: transform), to: outputBuffer)
        return (try preprocessor.packRGB(from: outputBuffer), mapping)
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
