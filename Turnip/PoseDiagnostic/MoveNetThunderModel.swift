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
    private let inputWidth: Int
    private let inputHeight: Int
    private let ciContext = CIContext()

    /// Loads the bundled model off the main thread. A `nonisolated async` function runs on the
    /// generic executor regardless of the caller's isolation, so the `Interpreter` construction and
    /// `allocateTensors()` inside `init` happen there. This is paid once per diagnostic run, not
    /// once per launch — every "Run diagnostic" tap builds a fresh model — so it must not block UI.
    nonisolated static func load() async throws -> MoveNetThunderModel {
        try MoveNetThunderModel()
    }

    private init() throws {
        // The .tflite is copied into a "Models/" subfolder of the bundle because project.yml
        // references Turnip/Models as a folder reference, not a group — so look it up there,
        // not at the bundle root.
        guard let modelPath = Bundle.main.path(
            forResource: "movenet_thunder_int8", ofType: "tflite", inDirectory: "Models"
        ) else {
            throw PoseDiagnosticError.modelNotFound
        }

        do {
            interpreter = try Interpreter(modelPath: modelPath)
            try interpreter.allocateTensors()
        } catch {
            throw PoseDiagnosticError.inferenceFailed("Failed to load MoveNet Thunder model: \(error.localizedDescription)")
        }

        // Read the input shape and data type at runtime rather than hardcoding 256x256/uint8,
        // so a future model swap (e.g. escalating to BlazePose per the design doc) doesn't
        // silently feed the wrong tensor size or element type.
        let inputTensor = try interpreter.input(at: 0)
        guard inputTensor.dataType == .uInt8 else {
            throw PoseDiagnosticError.inferenceFailed(
                "Model input wants \(inputTensor.dataType), the frame packing writes uInt8"
            )
        }
        let inputShape = inputTensor.shape.dimensions
        guard inputShape.count == 4 else {
            throw PoseDiagnosticError.inferenceFailed("Unexpected model input shape: \(inputShape)")
        }
        inputHeight = inputShape[1]
        inputWidth = inputShape[2]
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
        // A zero-area source would divide by zero in the scale factors below, producing an
        // infinite transform that silently corrupts the resize. Fail loudly instead: a
        // CVPixelBuffer-backed image should never have an empty extent.
        guard sourceImage.extent.width > 0, sourceImage.extent.height > 0 else {
            throw PoseDiagnosticError.inferenceFailed("Cannot resize a zero-area source frame")
        }
        let scaleX = CGFloat(inputWidth) / sourceImage.extent.width
        let scaleY = CGFloat(inputHeight) / sourceImage.extent.height
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var resizedBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, inputWidth, inputHeight, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &resizedBuffer
        )
        guard status == kCVReturnSuccess, let outputBuffer = resizedBuffer else {
            throw PoseDiagnosticError.inferenceFailed("Failed to allocate resize buffer")
        }

        ciContext.render(scaledImage, to: outputBuffer)

        CVPixelBufferLockBaseAddress(outputBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            throw PoseDiagnosticError.inferenceFailed("Failed to access resized pixel buffer")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let bgra = baseAddress.assumingMemoryBound(to: UInt8.self)
        let rgb = Self.rgb(from: bgra, rowBytes: bytesPerRow, width: inputWidth, height: inputHeight)

        return Data(rgb)
    }

    /// Reorders interleaved BGRA bytes into interleaved RGB, matching MoveNet Thunder's uint8
    /// `[1, height, width, 3]` input. A separate static so tests can exercise the byte layout
    /// directly: two things fail silently if done wrong — the rows must be stepped by `rowBytes`,
    /// not `width * 4` (the allocator pads rows to its own alignment, so the two differ for most
    /// widths and the offset drifts as the walk descends the frame), and the red and blue
    /// channels must be swapped (32BGRA stores blue first, the model expects RGB order).
    static func rgb(from bgraBytes: UnsafePointer<UInt8>, rowBytes: Int, width: Int, height: Int)
        -> [UInt8]
    {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for row in 0..<height {
            let rowStart = row * rowBytes
            for col in 0..<width {
                let pixelOffset = rowStart + col * 4
                let outIndex = (row * width + col) * 3
                rgb[outIndex] = bgraBytes[pixelOffset + 2]     // R
                rgb[outIndex + 1] = bgraBytes[pixelOffset + 1] // G
                rgb[outIndex + 2] = bgraBytes[pixelOffset]     // B
            }
        }
        return rgb
    }

    /// MoveNet's int8 build emits a quantized uint8 tensor; dequantize using the tensor's own
    /// scale/zero-point rather than assuming float32 output.
    private static func dequantize(_ tensor: Tensor) -> [Float] {
        if tensor.dataType == .uInt8, let quantization = tensor.quantizationParameters {
            return tensor.data.map { (Float($0) - Float(quantization.zeroPoint)) * quantization.scale }
        }

        let floatCount = tensor.data.count / MemoryLayout<Float32>.size
        return tensor.data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float32.self).prefix(floatCount))
        }
    }
}
