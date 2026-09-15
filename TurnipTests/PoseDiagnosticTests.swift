import CoreGraphics
import XCTest
@testable import Turnip

final class PoseDiagnosticTests: XCTestCase {
    // MARK: - Summary

    func testSummaryCountsFramesWithBothHipsAboveThreshold() {
        let frames = [
            frame(at: 0.0, hipConfidence: 0.9),
            frame(at: 0.1, hipConfidence: 0.9),
            frame(at: 0.2, hipConfidence: 0.1),
            frame(at: 0.3, hipConfidence: 0.9)
        ]

        let summary = PoseDiagnosticSummary(results: frames)

        XCTAssertEqual(summary.frameCount, 4)
        XCTAssertEqual(summary.framesWithUsableHips, 3)
        XCTAssertEqual(summary.usableHipsFraction, 0.75, accuracy: 0.0001)
    }

    /// A lone confident hip is not a usable pose: the motion signal needs the midpoint of both.
    func testSummaryRequiresBothHips() {
        let oneHip = PoseKeypoint.names.map { name in
            PoseKeypoint(name: name, y: 0.5, x: 0.5, confidence: name == "left_hip" ? 0.9 : 0.1)
        }
        let result = PoseFrameResult(frameIndex: 0, timestamp: 0, keypoints: oneHip)

        XCTAssertFalse(PoseDiagnosticSummary.hasUsableHips(result))
        XCTAssertEqual(PoseDiagnosticSummary(results: [result]).framesWithUsableHips, 0)
    }

    func testSummaryOfNoFramesIsAllZeroes() {
        let summary = PoseDiagnosticSummary(results: [])

        XCTAssertEqual(summary.frameCount, 0)
        XCTAssertEqual(summary.framesWithUsableHips, 0)
        XCTAssertEqual(summary.meanConfidence, 0)
        XCTAssertEqual(summary.usableHipsFraction, 0)
    }

    func testSummaryMeanConfidenceAveragesPerFrameAverages() {
        let frames = [
            frame(at: 0.0, hipConfidence: 0.2, otherConfidence: 0.2),
            frame(at: 0.1, hipConfidence: 0.6, otherConfidence: 0.6)
        ]

        XCTAssertEqual(PoseDiagnosticSummary(results: frames).meanConfidence, 0.4, accuracy: 0.0001)
    }

    // MARK: - Labels

    func testRowLabelsNameTheThresholdAndTheJointTotal() {
        let keypoints = PoseKeypoint.names.enumerated().map { index, name in
            PoseKeypoint(name: name, y: 0.5, x: 0.5, confidence: index < 9 ? 0.8 : 0.1)
        }
        let result = PoseFrameResult(frameIndex: 3, timestamp: 0.1, keypoints: keypoints)

        XCTAssertEqual(PoseDiagnosticLabels.rowTitle(for: result), "t=0.10s · frame 3")
        XCTAssertEqual(
            PoseDiagnosticLabels.rowDetail(for: result),
            "9 of 17 joints above 0.30 confidence · avg 0.47")
    }

    func testSummaryLabelReportsTheUsablePoseGateAsAPercentage() {
        let frames = [
            frame(at: 0.0, hipConfidence: 0.9, otherConfidence: 0.9),
            frame(at: 0.1, hipConfidence: 0.9, otherConfidence: 0.9),
            frame(at: 0.2, hipConfidence: 0.1, otherConfidence: 0.1)
        ]

        XCTAssertEqual(
            PoseDiagnosticLabels.summary(PoseDiagnosticSummary(results: frames)),
            "3 frames sampled · 2 (67%) with both hips above 0.30 · mean confidence 0.63")
    }

    /// The pre-run text is what stops the row stream reading as the video cut into pieces.
    func testExplanationSaysOneRowPerSampledFrame() {
        XCTAssertTrue(PoseDiagnosticLabels.explanation.contains("one row per sampled frame"))
        let rate = VideoFrameSampler.targetSamplesPerSecond
        XCTAssertTrue(PoseDiagnosticLabels.explanation.contains("\(rate) frames per second"))
    }

    // MARK: - Playhead → row

    func testNearestResultPicksTheCloserNeighbor() {
        let frames = [frame(at: 0.0), frame(at: 0.1), frame(at: 0.2), frame(at: 0.3)]

        XCTAssertEqual(PoseDiagnosticViewModel.nearestResult(to: 0.14, in: frames)?.timestamp, 0.1)
        XCTAssertEqual(PoseDiagnosticViewModel.nearestResult(to: 0.16, in: frames)?.timestamp, 0.2)
        XCTAssertEqual(PoseDiagnosticViewModel.nearestResult(to: 0.2, in: frames)?.timestamp, 0.2)
    }

    func testNearestResultClampsToTheEnds() {
        let frames = [frame(at: 0.5), frame(at: 0.6)]

        XCTAssertEqual(PoseDiagnosticViewModel.nearestResult(to: -1, in: frames)?.timestamp, 0.5)
        XCTAssertEqual(PoseDiagnosticViewModel.nearestResult(to: 9, in: frames)?.timestamp, 0.6)
        XCTAssertNil(PoseDiagnosticViewModel.nearestResult(to: 0, in: []))
    }

    // MARK: - Overlay geometry

    /// A 90°-rotated track (an iPhone portrait recording) must report portrait dimensions —
    /// the same size the sampler renders into, or the overlay would be transposed.
    func testDisplaySizeAppliesPreferredTransform() {
        let rotated = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

        let size = PoseDiagnosticViewModel.displaySize(
            naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: rotated)

        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(
            PoseDiagnosticViewModel.displaySize(
                naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: .identity),
            CGSize(width: 1920, height: 1080))
    }

    func testOverlayPointScalesNormalizedKeypointsWithoutClamping() {
        let inside = PoseKeypoint(name: "nose", y: 0.25, x: 0.5, confidence: 0.9)
        let padded = PoseKeypoint(name: "left_ankle", y: 1.2, x: -0.1, confidence: 0.9)
        let size = CGSize(width: 200, height: 100)

        XCTAssertEqual(PoseOverlayView.point(for: inside, in: size), CGPoint(x: 100, y: 25))
        XCTAssertEqual(PoseOverlayView.point(for: padded, in: size).x, -20, accuracy: 0.001)
        XCTAssertEqual(PoseOverlayView.point(for: padded, in: size).y, 120, accuracy: 0.001)
    }

    func testSkeletonEdgesOnlyNameRealKeypoints() {
        let names = Set(PoseKeypoint.names)
        for edge in PoseOverlayView.edges {
            XCTAssertTrue(names.contains(edge.0), "\(edge.0) is not a MoveNet keypoint")
            XCTAssertTrue(names.contains(edge.1), "\(edge.1) is not a MoveNet keypoint")
        }
    }

    // MARK: - Fixtures

    private func frame(
        at timestamp: TimeInterval, hipConfidence: Float = 0.9, otherConfidence: Float = 0.1
    ) -> PoseFrameResult {
        let keypoints = PoseKeypoint.names.map { name in
            PoseKeypoint(
                name: name, y: 0.5, x: 0.5,
                confidence: MotionSignalBuilder.hipKeypointNames.contains(name) ? hipConfidence : otherConfidence)
        }
        return PoseFrameResult(frameIndex: Int(timestamp * 30), timestamp: timestamp, keypoints: keypoints)
    }
}
