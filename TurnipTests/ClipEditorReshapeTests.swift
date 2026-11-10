import AVFoundation
import CoreGraphics
import XCTest
@testable import Turnip

/// The crop marker's corner handles: a drag reshapes the marker (`ClipEditorStage.resizedMarker`)
/// and letting go gives the clip that shape (`ClipEditorViewModel.resizeCrop`), with the picture
/// the drawn rectangle held filling the marker once it settles at its new shape.
final class ClipEditorReshapeTests: XCTestCase {
    /// 200x100 landscape source, as `ClipEditorTests`' follow fixtures.
    private let naturalSize = CGSize(width: 200, height: 100)
    private let stage = CGRect(x: 0, y: 113, width: 393, height: 500)

    /// The athlete at x≈0.3 for 2 s, then at x≈0.7 for 2 s.
    private func twoPositionFrames() -> [PoseFrameResult] {
        let early = (0..<20).map { 0.28 + 0.04 * Float($0) / 19 }
        let late = (0..<20).map { 0.68 + 0.04 * Float($0) / 19 }
        return PoseFixture.frames(hipXPositions: early + late)
    }

    @MainActor
    private func makeViewModel(
        followCrop: FollowCrop? = nil, frames: [PoseFrameResult]? = nil
    ) -> ClipEditorViewModel {
        let viewModel = ClipEditorViewModel(source: ClipEditorSource(
            window: TrickWindow(startTime: 0, endTime: 4),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            followCrop: followCrop,
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            poseFrames: frames ?? twoPositionFrames()))
        viewModel.setMediaInfo(duration: 60, naturalSize: naturalSize, preferredTransform: .identity)
        return viewModel
    }

    /// A turned crop at a zoom other than 1, with a keyframe at the playhead and one away from it.
    private func turnedCrop() -> FollowCrop {
        FollowCrop(
            keyframes: [
                FollowKeyframe(time: 0, center: CGPoint(x: 80, y: 45), scale: 1.6, rotationRadians: 0.2),
                FollowKeyframe(time: 3, center: CGPoint(x: 130, y: 55), scale: 2.4, rotationRadians: 0.2)
            ],
            resting: FollowFraming(center: CGPoint(x: 100, y: 50), scale: 1.6, rotationRadians: 0.2),
            isAutoFollow: false)
    }

    /// The source point, in displayed pixels, the editor draws at `point` on screen: the
    /// framing's center at the marker's center, zoomed by its scale times the placement's
    /// points per pixel and turned by its turn (`FollowPan`, `ClipEditorStage.videoPlacement`).
    private func sourcePoint(
        under point: CGPoint, marker: CGRect, cropRect: CGRect, framing: FollowFraming
    ) throws -> CGPoint {
        let placement = try XCTUnwrap(ClipEditorStage.videoPlacement(
            videoSize: naturalSize, cropRect: cropRect, marker: marker))
        let offset = CGPoint(
            x: (point.x - marker.midX) / placement.pointsPerDisplayedPixel,
            y: (point.y - marker.midY) / placement.pointsPerDisplayedPixel)
            .applying(CGAffineTransform(rotationAngle: -framing.rotationRadians))
        return CGPoint(
            x: framing.center.x + offset.x / framing.scale, y: framing.center.y + offset.y / framing.scale)
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        ClipEditorStage.Corner.allCases.map { $0.point(of: rect) }
    }

    // MARK: - Reshape

    /// What the drawn rectangle's corners showed before the release is what the settled marker's
    /// corners show after, at every keyframe and at rest — wherever the marker settles.
    @MainActor
    func testAReshapeKeepsThePictureUnderTheDrawnRectangle() throws {
        let viewModel = makeViewModel(followCrop: turnedCrop())
        let before = try XCTUnwrap(viewModel.followCrop)
        let cropRect = try XCTUnwrap(viewModel.previewOverlay?.cropRect)
        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: viewModel.targetAspectRatio)
        let placement = try XCTUnwrap(ClipEditorStage.videoPlacement(
            videoSize: naturalSize, cropRect: cropRect, marker: marker))
        let drawn = ClipEditorStage.resizedMarker(
            marker, corner: .bottomTrailing, translation: CGSize(width: 60, height: -170), in: stage)

        viewModel.resizeCrop(from: marker, to: drawn, previewScale: placement.pointsPerDisplayedPixel)

        let after = try XCTUnwrap(viewModel.followCrop)
        XCTAssertEqual(after.aspectRatio, drawn.width / drawn.height, accuracy: 1e-9)
        XCTAssertNotEqual(after.aspectRatio, before.aspectRatio)
        let settled = ClipEditorStage.markerRect(in: stage, aspectRatio: viewModel.targetAspectRatio)
        XCTAssertEqual(settled.width / settled.height, drawn.width / drawn.height, accuracy: 1e-6)
        let framings = zip(before.keyframes.map(\.framing), after.keyframes.map(\.framing))
            + [(before.resting, after.resting)]
        for (old, new) in framings {
            for (drawnCorner, settledCorner) in zip(corners(of: drawn), corners(of: settled)) {
                let shown = try sourcePoint(under: drawnCorner, marker: marker, cropRect: cropRect, framing: old)
                let lands = try sourcePoint(under: settledCorner, marker: settled, cropRect: cropRect, framing: new)
                XCTAssertEqual(lands.x, shown.x, accuracy: 1e-6)
                XCTAssertEqual(lands.y, shown.y, accuracy: 1e-6)
            }
            XCTAssertEqual(new.rotationRadians, old.rotationRadians)
        }
    }

    /// A reshape is the user's change: Auto follow is offered again for the new shape, and every
    /// keyframe becomes the user's own, keeping none of Auto follow's values fitted to the old
    /// shape, so removing one deletes it rather than restoring a framing for another box.
    @MainActor
    func testAReshapeIsTheUsersChange() throws {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.isAutoFollowApplied)
        let auto = try XCTUnwrap(viewModel.followCrop)
        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: viewModel.targetAspectRatio)
        let placement = try XCTUnwrap(ClipEditorStage.videoPlacement(
            videoSize: naturalSize, cropRect: try XCTUnwrap(viewModel.previewOverlay?.cropRect), marker: marker))

        viewModel.resizeCrop(
            from: marker, to: marker.insetBy(dx: 20, dy: 40).offsetBy(dx: 10, dy: 0),
            previewScale: placement.pointsPerDisplayedPixel)

        let reshaped = try XCTUnwrap(viewModel.followCrop)
        XCTAssertFalse(viewModel.isAutoFollowApplied)
        XCTAssertFalse(reshaped.isUntouchedAutoFollow)
        XCTAssertTrue(reshaped.keyframes.allSatisfy { !$0.isAutoFollows })
        XCTAssertTrue(reshaped.keyframes.allSatisfy { $0.autoFraming == nil })
        XCTAssertEqual(reshaped.keyframes.map(\.time), auto.keyframes.map(\.time))
        let first = reshaped.keyframes[0]
        viewModel.removeKeyframe(first)
        let remaining = try XCTUnwrap(viewModel.followCrop?.keyframes)
        XCTAssertEqual(remaining.map(\.time), Array(auto.keyframes.dropFirst()).map(\.time))
        XCTAssertEqual(remaining, Array(reshaped.keyframes.dropFirst()))
    }

    /// A handle's touch target stays inside the stage: a marker at the stage's insets has its
    /// top and bottom targets slid inward, square and over their corners still, leaving the band
    /// above to the drag that closes the editor; one well inside keeps its target centered.
    func testAHandleTargetStaysInsideTheStage() {
        let side: CGFloat = 44
        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: 9.0 / 16)
        XCTAssertEqual(marker.minY, stage.minY + ClipEditorStage.verticalInset, accuracy: 1e-9)
        for corner in ClipEditorStage.Corner.allCases {
            let point = corner.point(of: marker)
            let target = ClipEditorStage.handleTarget(at: point, side: side, in: stage)
            XCTAssertEqual(target.size, CGSize(width: side, height: side), "\(corner)")
            XCTAssertTrue(stage.contains(target), "\(corner)")
            XCTAssertTrue(target.contains(point), "\(corner)")
            XCTAssertEqual(target.midX, point.x, accuracy: 1e-9, "\(corner)")
        }
        let topLeading = ClipEditorStage.handleTarget(
            at: ClipEditorStage.Corner.topLeading.point(of: marker), side: side, in: stage)
        XCTAssertEqual(topLeading.minY, stage.minY, accuracy: 1e-9)
        let bottomTrailing = ClipEditorStage.handleTarget(
            at: ClipEditorStage.Corner.bottomTrailing.point(of: marker), side: side, in: stage)
        XCTAssertEqual(bottomTrailing.maxY, stage.maxY, accuracy: 1e-9)

        let inside = CGPoint(x: stage.midX, y: stage.midY)
        let centered = ClipEditorStage.handleTarget(at: inside, side: side, in: stage)
        XCTAssertEqual(centered.midX, inside.x, accuracy: 1e-9)
        XCTAssertEqual(centered.midY, inside.y, accuracy: 1e-9)
    }

    /// The shape is the clip's: Auto follow, Reset follow and a trim's re-track all keep it, and
    /// the commit carries it even for a clip that opened on Auto follow's crop.
    @MainActor
    func testTheShapeOutlivesAutoFollowResetAndTrim() throws {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.result.followCrop)
        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: viewModel.targetAspectRatio)
        let square = CGRect(
            x: marker.minX, y: marker.midY - marker.width / 2, width: marker.width, height: marker.width)

        viewModel.resizeCrop(from: marker, to: square, previewScale: 1)

        XCTAssertEqual(viewModel.targetAspectRatio, 1, accuracy: 1e-9)
        XCTAssertEqual(viewModel.result.followCrop?.aspectRatio ?? 0, 1, accuracy: 1e-9)
        viewModel.autoFollow()
        XCTAssertTrue(viewModel.isAutoFollowApplied)
        XCTAssertEqual(viewModel.followCrop?.aspectRatio ?? 0, 1, accuracy: 1e-9)
        viewModel.trimEnd(to: 3)
        viewModel.finishTrim()
        XCTAssertEqual(viewModel.followCrop?.aspectRatio ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(viewModel.followCrop?.isUntouchedAutoFollow == true, "re-tracked, not left behind")
        viewModel.resetFollow()
        XCTAssertEqual(viewModel.followCrop?.aspectRatio ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(viewModel.followCrop?.keyframes, [])
    }

    /// Letting go where the handle was picked up changes nothing.
    @MainActor
    func testAReshapeBackToTheSameMarkerChangesNothing() throws {
        let viewModel = makeViewModel(followCrop: turnedCrop())
        let before = viewModel.followCrop
        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: viewModel.targetAspectRatio)

        viewModel.resizeCrop(from: marker, to: marker, previewScale: 0.5)

        XCTAssertEqual(viewModel.followCrop, before)
    }

    /// Past the shapes allowed, the drawn rectangle gives up its longer side about its center:
    /// a VoiceOver Make crop wider at the widest shape changes nothing.
    @MainActor
    func testAReshapePastTheWidestShapeStopsThere() throws {
        let viewModel = makeViewModel(followCrop: turnedCrop())
        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: viewModel.targetAspectRatio)
        let wide = CGRect(x: marker.midX - 300, y: marker.midY - 50, width: 600, height: 100)

        viewModel.resizeCrop(from: marker, to: wide, previewScale: 0.5)
        let widest = try XCTUnwrap(viewModel.followCrop)
        XCTAssertEqual(widest.aspectRatio, ClipEditorStage.aspectRatioRange.upperBound, accuracy: 1e-9)

        let settled = ClipEditorStage.markerRect(in: stage, aspectRatio: widest.aspectRatio)
        let wider = CGRect(
            x: settled.midX - settled.width * 0.625, y: settled.minY,
            width: settled.width * 1.25, height: settled.height)
        viewModel.resizeCrop(from: settled, to: wider, previewScale: 0.5)
        XCTAssertEqual(viewModel.followCrop, widest)
    }

    // MARK: - Corner drag

    func testACornerDragHoldsTheCornerAcrossFromIt() {
        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: 9.0 / 16.0)

        let drawn = ClipEditorStage.resizedMarker(
            marker, corner: .topLeading, translation: CGSize(width: 30, height: 80), in: stage)

        XCTAssertEqual(drawn.maxX, marker.maxX, accuracy: 1e-9)
        XCTAssertEqual(drawn.maxY, marker.maxY, accuracy: 1e-9)
        XCTAssertEqual(drawn.minX, marker.minX + 30, accuracy: 1e-9)
        XCTAssertEqual(drawn.minY, marker.minY + 80, accuracy: 1e-9)
    }

    /// The marker stays inside the stage's insets, never under `minimumMarkerSide`, and within
    /// `aspectRatioRange`, however far the finger goes.
    func testACornerDragStaysInsideTheStageAndTheShapesAllowed() {
        let available = stage.insetBy(dx: ClipEditorStage.horizontalInset, dy: ClipEditorStage.verticalInset)
        let marker = ClipEditorStage.markerRect(in: stage, aspectRatio: 9.0 / 16.0)
        let translations = [
            CGSize(width: 500, height: 500), CGSize(width: -900, height: 10), CGSize(width: 10, height: -900),
            CGSize(width: -900, height: -900), CGSize(width: 400, height: -400), CGSize(width: -60, height: 0)
        ]
        for corner in ClipEditorStage.Corner.allCases {
            for translation in translations {
                let drawn = ClipEditorStage.resizedMarker(marker, corner: corner, translation: translation, in: stage)
                let label = "\(corner) by \(translation)"
                XCTAssertTrue(available.insetBy(dx: -1e-9, dy: -1e-9).contains(drawn), label)
                XCTAssertGreaterThanOrEqual(drawn.width, ClipEditorStage.minimumMarkerSide - 1e-9, label)
                XCTAssertGreaterThanOrEqual(drawn.height, ClipEditorStage.minimumMarkerSide - 1e-9, label)
                XCTAssertTrue(
                    ClipEditorStage.aspectRatioRange.contains(drawn.width / drawn.height), label)
                XCTAssertEqual(
                    corner.opposite.point(of: drawn), corner.opposite.point(of: marker), "\(label) held corner")
            }
        }
    }

    func testAShapeOutOfRangeGivesUpItsLongerSideAboutItsCenter() {
        let wide = CGRect(x: 0, y: 0, width: 500, height: 100)

        let clamped = ClipEditorStage.clampedShape(wide)

        XCTAssertEqual(clamped.width, 200, accuracy: 1e-9)
        XCTAssertEqual(clamped.height, 100, accuracy: 1e-9)
        XCTAssertEqual(clamped.midX, wide.midX, accuracy: 1e-9)
        let tall = CGRect(x: 0, y: 0, width: 100, height: 500)
        XCTAssertEqual(ClipEditorStage.clampedShape(tall).height, 200, accuracy: 1e-9)
        XCTAssertEqual(ClipEditorStage.clampedShape(tall).midY, tall.midY, accuracy: 1e-9)
        let square = CGRect(x: 3, y: 4, width: 100, height: 100)
        XCTAssertEqual(ClipEditorStage.clampedShape(square), square)
    }
}
