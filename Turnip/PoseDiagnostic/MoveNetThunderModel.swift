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

    /// Loads the bundled model off the main thread. A `nonisolated async` function runs on the
    /// generic executor regardless of the caller's isolation, so the `Interpreter` construction and
    /// `allocateTensors()` inside `init` happen there. This is paid once per diagnostic run, not
    /// once per launch — every "Run diagnostic" tap builds a fresh model — so it must not block UI.
    nonisolated static func load() async throws -> MoveNetThunderModel {
        try MoveNetThunderModel()
    }

    private init() throws {
        guard let modelPath = Bundle.main.path(forResource: "movenet_thunder_int8", ofType: "tflite") else {
            throw PoseDiagnosticError.modelNotFound
        }

        do {
            interpreter = try Interpreter(modelPath: modelPath)
            try interpreter.allocateTensors()
        } catch {
            throw PoseDiagnosticError.inferenceFailed(
                "Failed to load MoveNet Thunder model: \(error.localizedDescription)"
            )
        }

        // Read the input tensor at runtime rather than hardcoding 256x256 uint8, so a future
        // model swap (e.g. escalating to BlazePose per the design doc) doesn't silently
        // feed the wrong tensor size or element type.
        let inputTensor = try interpreter.input(at: 0)
        guard inputTensor.dataType == .uInt8 else {
            throw PoseDiagnosticError.inferenceFailed(
                "Model input wants \(inputTensor.dataType), the frame packing writes uInt8"
            )
        }
        preprocessor = try FramePreprocessor(inputShape: inputTensor.shape.dimensions)
    }

    func runInference(on pixelBuffer: CVPixelBuffer) throws -> [PoseKeypoint] {
        let inputData = try resizedRGBData(from: pixelBuffer)
        try interpreter.copy(inputData, toInputAt: 0)
        try interpreter.invoke()
        let outputTensor = try interpreter.output(at: 0)
        let values = Self.dequantize(outputTensor)
        return try PoseKeypoint.parse(from: values)
    }

    /// Resizes the source frame to the model's input size and packs it as interleaved RGB uint8,
    /// matching MoveNet Thunder's expected [1, height, width, 3] input tensor.
    private func resizedRGBData(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let transform = preprocessor.scaleTransform(forSourceExtent: sourceImage.extent)
        let outputBuffer = try preprocessor.makeTargetBuffer()
        ciContext.render(sourceImage.transformed(by: transform), to: outputBuffer)
        return try preprocessor.packRGB(from: outputBuffer)
    }

    /// MoveNet's int8 build emits a quantized uint8 tensor; dequantize using the tensor's own
    /// scale/zero-point rather than assuming float32 output.
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
