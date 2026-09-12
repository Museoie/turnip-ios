import Foundation

/// Turns a model output tensor's raw bytes into floats.
///
/// Takes the values rather than a `Tensor` because TensorFlowLiteSwift declares neither
/// `Tensor.init` nor `QuantizationParameters.init` public, so nothing outside the pod — a test
/// included — can build one to pass in. `MoveNetThunderModel` unpacks the tensor and calls in here.
enum TensorDequantizer {
    /// Undoes affine uint8 quantization: `value = (byte - zeroPoint) * scale`.
    static func floats(fromUInt8 data: Data, scale: Float, zeroPoint: Int) -> [Float] {
        data.map { (Float($0) - Float(zeroPoint)) * scale }
    }

    /// Reinterprets the bytes as float32. Trailing bytes that do not complete a float are dropped
    /// rather than read past the end of the buffer.
    static func floats(fromFloat32 data: Data) -> [Float] {
        let floatCount = data.count / MemoryLayout<Float32>.size
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float32.self).prefix(floatCount))
        }
    }
}
