import AVFoundation
import Foundation
import XCTest
@testable import Turnip

/// A stand-in for a tile's real loop: records the lifecycle calls it received and the
/// geometry it was built over, so a test can assert both what ran and which range, through
/// which framing, would have played.
private final class FakeLoop: ClipLooping {
    let player = AVQueuePlayer()
    let geometry: ClipCardPlaybackGeometry
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0

    init(geometry: ClipCardPlaybackGeometry) {
        self.geometry = geometry
    }

    func play() {
        playCount += 1
    }

    func pause() {
        pauseCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

/// Every loop `ClipCardPlayback` asked for and every framing it loaded a composition for,
/// both in order, plus the two accessibility settings behind its gate. A class so a test
/// can flip either setting after construction — both can change while a tile is mounted.
private final class LoopRecorder {
    struct CompositionRequest: Equatable {
        let cropRect: NormalizedRect
        let cropAdjustment: CropAdjustment
    }

    var isVideoAutoplayEnabled = true
    var isReduceMotionEnabled = false
    var duration: TimeInterval?
    var loops: [FakeLoop] = []
    var compositionRequests: [CompositionRequest] = []
}

@MainActor
final class ClipCardPlaybackTests: XCTestCase {
    private let window = TrickWindow(startTime: 2, endTime: 5)
    /// The same clip after an editor commit shortened its end. Distinct from `window`, so
    /// a rebuild that reuses the pre-edit loop is visible rather than indistinguishable.
    private let editedWindow = TrickWindow(startTime: 2, endTime: 3.5)
    private let cropRect = NormalizedRect(minX: 0.1, maxX: 0.6, minY: 0.1, maxY: 0.6)
    /// A crop-area pan with the window left alone — the edit that has to rebuild on its
    /// own, since a composition is what carries framing and the looper's time range is
    /// unchanged by it.
    private let pannedCropRect = NormalizedRect(minX: 0.4, maxX: 0.9, minY: 0.1, maxY: 0.6)
    private let rotation = CropAdjustment(scale: 1, rotationRadians: 0.5, offset: .zero)

    private func geometry(
        window: TrickWindow? = nil,
        cropRect: NormalizedRect? = nil,
        cropAdjustment: CropAdjustment = .identity
    ) -> ClipCardPlaybackGeometry {
        ClipCardPlaybackGeometry(
            window: window ?? self.window,
            cropRect: cropRect ?? self.cropRect,
            cropAdjustment: cropAdjustment)
    }

    /// `AVAsset` is abstract and throws at runtime, so this uses the concrete
    /// `AVURLAsset`. The URL resolves to nothing and never needs to — no test here builds
    /// a real loop over it.
    ///
    /// The gate closure runs the production rule over the recorder's settings rather than
    /// restating `&&` here, so dropping either condition from `clipCardMayAutoplayLoops`
    /// fails the tests below instead of only the truth table.
    private func makePlayback(_ recorder: LoopRecorder) -> ClipCardPlayback {
        ClipCardPlayback(
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            mayAutoplayLoops: {
                clipCardMayAutoplayLoops(
                    isVideoAutoplayEnabled: recorder.isVideoAutoplayEnabled,
                    isReduceMotionEnabled: recorder.isReduceMotionEnabled)
            },
            loadComposition: { cropRect, cropAdjustment in
                recorder.compositionRequests.append(
                    LoopRecorder.CompositionRequest(
                        cropRect: cropRect, cropAdjustment: cropAdjustment))
                return nil
            },
            loadDuration: { recorder.duration },
            makeLoop: { _, geometry, _ in
                let loop = FakeLoop(geometry: geometry)
                recorder.loops.append(loop)
                return loop
            })
    }

    /// Loop construction is deferred behind the composition load, so nothing built by a
    /// call is observable until that build finishes. Reads the task before awaiting it —
    /// a finished build clears the slot.
    private func settle(_ playback: ClipCardPlayback) async {
        await playback.buildTask?.value
    }

    // MARK: - The gate on auto-playing loops

    func testTheGateWantsBothSettingsToAllowLooping() {
        XCTAssertTrue(
            clipCardMayAutoplayLoops(isVideoAutoplayEnabled: true, isReduceMotionEnabled: false))
        XCTAssertFalse(
            clipCardMayAutoplayLoops(isVideoAutoplayEnabled: false, isReduceMotionEnabled: false))
        XCTAssertFalse(
            clipCardMayAutoplayLoops(isVideoAutoplayEnabled: true, isReduceMotionEnabled: true))
        XCTAssertFalse(
            clipCardMayAutoplayLoops(isVideoAutoplayEnabled: false, isReduceMotionEnabled: true))
    }

    /// Nothing is built and nothing is even loaded: the composition load is the expensive
    /// half, so a gate that only skipped the loop would still pay for it.
    func testAutoplayDisabledBuildsNoLoopAtAll() async {
        let recorder = LoopRecorder()
        recorder.isVideoAutoplayEnabled = false
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        XCTAssertTrue(recorder.compositionRequests.isEmpty)
        XCTAssertTrue(recorder.loops.isEmpty)
        XCTAssertNil(playback.loop)
    }

    func testAutoplayDisabledWhileSuspendedKeepsTheTilePausedOnResume() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)
        playback.setSuspended(true)

        recorder.isVideoAutoplayEnabled = false
        playback.setSuspended(false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].playCount, 1)
        XCTAssertEqual(recorder.loops[0].pauseCount, 1)
    }

    /// Reduce Motion is the other half of the checklist's requirement, and a separate
    /// Settings switch: it has to stop the loop on its own, with Auto-Play Video Previews
    /// left at its default.
    func testReduceMotionBuildsNoLoopWithAutoplayStillOn() async {
        let recorder = LoopRecorder()
        recorder.isReduceMotionEnabled = true
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        XCTAssertTrue(recorder.isVideoAutoplayEnabled)
        XCTAssertTrue(recorder.loops.isEmpty)
        XCTAssertNil(playback.loop)
    }

    func testReduceMotionTurnedOnWhileSuspendedKeepsTheTilePausedOnResume() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)
        playback.setSuspended(true)

        recorder.isReduceMotionEnabled = true
        playback.setSuspended(false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].playCount, 1)
        XCTAssertEqual(recorder.loops[0].pauseCount, 1)
    }

    // MARK: - Mounting and releasing

    func testStartBuildsALoopOverTheItemsGeometryAndPlaysIt() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(cropAdjustment: rotation), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(
            recorder.compositionRequests,
            [LoopRecorder.CompositionRequest(cropRect: cropRect, cropAdjustment: rotation)])
        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].geometry, geometry(cropAdjustment: rotation))
        XCTAssertEqual(recorder.loops[0].playCount, 1)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[0])
    }

    func testStartWhileSuspendedBuildsNoLoop() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: true)
        await settle(playback)

        XCTAssertTrue(recorder.loops.isEmpty)
        XCTAssertNil(playback.loop)
    }

    func testRepeatedStartResumesTheSameLoop() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].playCount, 2)
    }

    /// `.task(id: item)` and `.onAppear` both fire on a tile's first appearance, so two
    /// starts for one target routinely land before either has a loop. The second joins the
    /// build in flight instead of racing a duplicate decoder onto the same tile.
    func testTwoStartsBeforeTheFirstBuildFinishesBuildOneLoop() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: false)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.compositionRequests.count, 1)
        XCTAssertEqual(recorder.loops.count, 1)
    }

    /// A start for a DIFFERENT target does replace the build in flight: letting the loser
    /// finish would record its geometry as the mounted one and mask the rebuild the live
    /// target needs.
    func testAStartForANewTargetReplacesTheBuildInFlight() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: false)
        let replaced = playback.buildTask
        playback.start(geometry: geometry(window: editedWindow), isSuspended: false)
        await replaced?.value
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].geometry.window, editedWindow)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[0])
    }

    /// The window can also arrive through `start` — `.task(id: item)` re-fires on an
    /// editor commit — with the pre-edit loop still mounted and nothing having torn it
    /// down. Asserts the *new* loop's range, so reusing the stale one fails.
    func testStartWithAChangedWindowRebuildsOverTheNewRange() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        playback.start(geometry: geometry(window: editedWindow), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertEqual(recorder.loops[1].geometry.window, editedWindow)
        XCTAssertEqual(recorder.loops[1].playCount, 1)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[1])
    }

    /// A crop-area pan leaves the window alone, so a rebuild keyed on the window would
    /// keep playing the pre-edit framing. Asserts the framing the new loop was built with
    /// AND the framing its composition was loaded for — the composition is what actually
    /// renders the crop.
    func testStartWithAChangedCropRectAloneRebuildsOverTheNewFraming() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        playback.start(geometry: geometry(cropRect: pannedCropRect), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertEqual(recorder.loops[1].geometry.window, window)
        XCTAssertEqual(recorder.loops[1].geometry.cropRect, pannedCropRect)
        XCTAssertEqual(recorder.compositionRequests.map(\.cropRect), [cropRect, pannedCropRect])
    }

    /// Rotation is stored apart from `cropRect` and an editor commit can change it alone,
    /// so it has to key the rebuild on its own too.
    func testStartWithAChangedCropAdjustmentAloneRebuildsOverTheNewFraming() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        playback.start(geometry: geometry(cropAdjustment: rotation), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[1].geometry.cropAdjustment, rotation)
        XCTAssertEqual(
            recorder.compositionRequests.map(\.cropAdjustment), [.identity, rotation])
    }

    func testTeardownReleasesTheLoop() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        playback.teardown()

        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertNil(playback.loop)
    }

    /// A tile scrolled off mid-load must not have a decoder assigned to it after the fact
    /// — `teardown` cancels the build, it doesn't only release an already-built loop.
    func testTeardownBeforeTheBuildFinishesAssignsNoLoop() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: false)
        let cancelled = playback.buildTask
        playback.teardown()
        await cancelled?.value

        XCTAssertTrue(recorder.loops.isEmpty)
        XCTAssertNil(playback.loop)
    }

    /// The editor opening mid-load is the same hazard from the other direction:
    /// `setSuspended` can only pause a loop that already exists, so the load itself has to
    /// re-check before assigning one behind the cover. The tile then comes back on resume.
    func testSuspendingBeforeTheBuildFinishesAssignsNoLoopAndResumeBuildsOne() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: false)
        playback.setSuspended(true)
        await settle(playback)
        XCTAssertTrue(recorder.loops.isEmpty)
        XCTAssertNil(playback.loop)

        playback.setSuspended(false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].geometry, geometry())
        XCTAssertEqual(recorder.loops[0].playCount, 1)
    }

    func testStartAfterTeardownBuildsAFreshLoop() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)
        playback.teardown()

        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[1].playCount, 1)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[1])
    }

    // MARK: - Suspension while the editor covers the grid

    func testSuspendingPausesWithoutReleasingTheLoop() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        playback.setSuspended(true)

        XCTAssertEqual(recorder.loops[0].pauseCount, 1)
        XCTAssertEqual(recorder.loops[0].stopCount, 0)
        XCTAssertNotNil(playback.loop)
    }

    func testResumingReusesTheMountedLoop() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)
        playback.setSuspended(true)

        playback.setSuspended(false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].playCount, 2)
    }

    // MARK: - An editor commit that moves the window

    func testWindowChangeRebuildsTheLoopOverTheNewRange() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        playback.windowChanged(to: editedWindow)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertEqual(recorder.loops[1].geometry.window, editedWindow)
        XCTAssertEqual(recorder.loops[1].playCount, 1)
        XCTAssertIdentical(playback.loop as? FakeLoop, recorder.loops[1])
    }

    /// The window arrives through an `.onChange` closure that carries no framing, so the
    /// rebuild has to take the framing from what the lifecycle already stored — reading it
    /// off a stale view would resume on pre-edit framing and record that as the mounted
    /// geometry, masking the rebuild a later crop edit needs.
    func testWindowChangeKeepsTheFramingItWasAlreadyBuiltFor() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(cropAdjustment: rotation), isSuspended: false)
        await settle(playback)

        playback.windowChanged(to: editedWindow)
        await settle(playback)

        XCTAssertEqual(
            recorder.loops[1].geometry,
            geometry(window: editedWindow, cropAdjustment: rotation))
    }

    func testWindowChangeWhileSuspendedRebuildsOnResumeNotOnThePreEditRange() async {
        let recorder = LoopRecorder()
        let playback = makePlayback(recorder)
        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)
        playback.setSuspended(true)

        playback.windowChanged(to: editedWindow)
        await settle(playback)
        XCTAssertEqual(recorder.loops[0].stopCount, 1)
        XCTAssertNil(playback.loop)

        // No window argument: the rebuild can only come from what `windowChanged` stored,
        // so the assertion below can't pass on a value this test just handed in.
        playback.setSuspended(false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 2)
        XCTAssertEqual(recorder.loops[1].geometry.window, editedWindow)
        XCTAssertEqual(recorder.loops[1].playCount, 1)
    }

    // MARK: - Clamping a window that overshoots the asset's duration

    /// The detector's trailing buffer can leave `endTime` past the asset's real duration —
    /// most often on the last detected trick, whose landing tends to sit closest to when
    /// recording stopped. `AVPlayerLooper` never surfaces a failure for an out-of-bounds
    /// range; it just never queues a playable item, so the build has to clamp before
    /// handing the range to `makeLoop`.
    func testStartClampsAWindowThatOvershootsTheLoadedDuration() async {
        let recorder = LoopRecorder()
        recorder.duration = 4
        let overshooting = TrickWindow(startTime: 2, endTime: 5)
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(window: overshooting), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(
            recorder.loops[0].geometry.window,
            ClipEditorViewModel.clamped(window: overshooting, to: 4))
    }

    /// A window already inside the duration builds unchanged — the clamp is a no-op, not a
    /// second source of truth that could disagree with the item's own window.
    func testStartWithAWindowInsideTheDurationBuildsItUnchanged() async {
        let recorder = LoopRecorder()
        recorder.duration = 10
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops[0].geometry.window, window)
    }

    /// The rebuild check compares the item's own (unclamped) geometry, not the clamped one
    /// the loop was actually built with — otherwise every later resume of an overshooting
    /// clip would see its stored `loopGeometry` disagree with the item's window and
    /// rebuild forever instead of just resuming.
    func testRepeatedStartOfAnOvershootingWindowResumesRatherThanRebuilding() async {
        let recorder = LoopRecorder()
        recorder.duration = 4
        let overshooting = TrickWindow(startTime: 2, endTime: 5)
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(window: overshooting), isSuspended: false)
        await settle(playback)
        playback.start(geometry: geometry(window: overshooting), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops.count, 1)
        XCTAssertEqual(recorder.loops[0].playCount, 2)
    }

    /// The duration can't be read at all (`nil`, not merely pending — the build already
    /// awaits it): builds the raw window unclamped rather than refusing to play.
    func testStartWithAnUnreadableDurationBuildsTheRawWindow() async {
        let recorder = LoopRecorder()
        let overshooting = TrickWindow(startTime: 2, endTime: 5)
        let playback = makePlayback(recorder)

        playback.start(geometry: geometry(window: overshooting), isSuspended: false)
        await settle(playback)

        XCTAssertEqual(recorder.loops[0].geometry.window, overshooting)
    }
}
