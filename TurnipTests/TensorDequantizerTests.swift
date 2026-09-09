import XCTest
@testable import Turnip

final class TensorDequantizerTests: XCTestCase {
    func testUInt8BranchAppliesZeroPointThenScale() {
        let values = TensorDequantizer.floats(fromUInt8: Data([0, 64, 128, 255]), scale: 0.5, zeroPoint: 128)

        XCTAssertEqual(values, [-64, -32, 0, 63.5])
    }

    func testUInt8BranchEmitsOneFloatPerByte() {
        let data = Data(repeating: 7, count: 51)

        XCTAssertEqual(TensorDequantizer.floats(fromUInt8: data, scale: 1, zeroPoint: 0).count, 51)
    }

    func testFloat32BranchReinterpretsBytesInOrder() {
        let source: [Float32] = [1.5, -2.25, 0, 3, 0.001, -0.001, 100, -100]
        let data = source.withUnsafeBytes { Data($0) }

        let values = TensorDequantizer.floats(fromFloat32: data)

        XCTAssertEqual(values.count, source.count)
        for (value, expected) in zip(values, source) {
            XCTAssertEqual(value, expected, accuracy: 0.0000001)
        }
    }

    func testFloat32BranchDropsATrailingPartialFloat() {
        let source: [Float32] = [1.5, -2.25, 0, 3, 0.001, -0.001, 100, -100]
        var data = source.withUnsafeBytes { Data($0) }
        data.append(0x7f)

        XCTAssertEqual(TensorDequantizer.floats(fromFloat32: data).count, source.count)
    }
}
