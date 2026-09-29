import XCTest
@testable import Turnip

final class ScrubCalculatorTests: XCTestCase {

    private let epsilon = 1e-9

    // MARK: - Basic normalization

    func testHalfScreenRightIsHalfTheTimeline() {
        let result = ScrubCalculator.calculate(
            translation: CGSize(width: 500, height: 0),
            viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(result.timelineDelta, 1, accuracy: epsilon)
    }

    func testOneScreenRightIsTheWholeTimeline() {
        let result = ScrubCalculator.calculate(
            translation: CGSize(width: 1000, height: 0),
            viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(result.timelineDelta, 2, accuracy: epsilon)
    }

    func testTwoScreensRightClampsToTheWholeTimeline() {
        let result = ScrubCalculator.calculate(
            translation: CGSize(width: 2000, height: 0),
            viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(result.timelineDelta, 2, accuracy: epsilon)
    }

    func testAZeroWidthViewportProducesNoMovement() {
        let result = ScrubCalculator.calculate(
            translation: CGSize(width: 500, height: 0),
            viewportSize: .zero)
        XCTAssertEqual(result.timelineDelta, 0, accuracy: epsilon)
    }

    // MARK: - Left/right symmetry

    func testHorizontalDirectionIsSymmetric() {
        let right = ScrubCalculator.calculate(
            translation: CGSize(width: 500, height: 0),
            viewportSize: CGSize(width: 1000, height: 800))
        let left = ScrubCalculator.calculate(
            translation: CGSize(width: -500, height: 0),
            viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(right.timelineDelta, -left.timelineDelta, accuracy: epsilon)
    }

    // MARK: - Vertical sensitivity

    func testDownwardDragDoesNotAffectSensitivity() {
        let horizontalOnly = ScrubCalculator.calculate(
            translation: CGSize(width: 500, height: 0),
            viewportSize: CGSize(width: 1000, height: 800))
        let downward = ScrubCalculator.calculate(
            translation: CGSize(width: 500, height: 300),
            viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(horizontalOnly.timelineDelta, downward.timelineDelta, accuracy: epsilon)
    }

    func testUpwardMovementReducesSensitivity() {
        let low = ScrubCalculator.calculate(
            translation: CGSize(width: 500, height: -100),
            viewportSize: CGSize(width: 1000, height: 800))
        let high = ScrubCalculator.calculate(
            translation: CGSize(width: 500, height: -1000),
            viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertGreaterThan(low.timelineDelta, high.timelineDelta)
    }

    // MARK: - Range

    func testMagnitudeNeverExceedsTheClampedRange() {
        let result = ScrubCalculator.calculate(
            translation: CGSize(width: 10_000, height: 0),
            viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(result.timelineDelta, 2, accuracy: epsilon)
    }

    // MARK: - No vertical movement: t = x, unbounded by t = 2

    func testCalculateNormalizedIsDirectlyProportionalBelowTheTrack() {
        XCTAssertEqual(ScrubCalculator.calculateNormalized(horizontal: 0.25, vertical: 0), 0.25, accuracy: epsilon)
        XCTAssertEqual(ScrubCalculator.calculateNormalized(horizontal: 1.5, vertical: 0), 1.5, accuracy: epsilon)
        XCTAssertEqual(ScrubCalculator.calculateNormalized(horizontal: 2.0, vertical: 0), 2.0, accuracy: epsilon)
    }

    // MARK: - Mathematical line tests
    //
    // The design doc's diagram defines, for the upward branch, lines of constant t:
    //   y = ((2 - t) / t) * x - (2 - t)
    // Each line only enters the upward branch (y > 0) where x > t; points are chosen there.

    func testPointsOnTheConstantTLinesReturnThatT() {
        for eighths in 1...7 {
            let t = Double(eighths) / 8
            let slope = (2 - t) / t
            let intercept = -(2 - t)
            for x in stride(from: t + 0.05, through: 2.0, by: 0.2) {
                let y = slope * x + intercept
                guard y > 0 else { continue }
                let calculated = ScrubCalculator.calculateNormalized(horizontal: x, vertical: y)
                XCTAssertEqual(
                    calculated, t, accuracy: 1e-6,
                    "x=\(x) y=\(y) expected t=\(t) got \(calculated)")
            }
        }
    }

    /// `t = 2` is the `y = 0` line's other root, which belongs to the `y <= 0` rule rather
    /// than the upward branch — so it's exercised as the limit of the upward branch as
    /// `y` approaches zero, at the one point (`x = 2`) where that branch's smaller root
    /// equals `2` in the limit.
    func testTEqualsTwoIsTheLimitOfTheUpwardBranchAsYApproachesZero() {
        let calculated = ScrubCalculator.calculateNormalized(horizontal: 2, vertical: 1e-9)
        XCTAssertEqual(calculated, 2, accuracy: 1e-4)
    }

    // MARK: - The x > 2 discontinuity at y = 0 is intentional

    func testXGreaterThanTwoAtYZeroUsesXDirectly() {
        XCTAssertEqual(ScrubCalculator.calculateNormalized(horizontal: 2.5, vertical: 0), 2.5, accuracy: epsilon)
    }

    func testXGreaterThanTwoJustAboveYZeroDropsTowardTwo() {
        let calculated = ScrubCalculator.calculateNormalized(horizontal: 2.5, vertical: 1e-6)
        XCTAssertEqual(calculated, 2, accuracy: 1e-3)
    }
}
