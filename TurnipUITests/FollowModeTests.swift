import XCTest

/// The clip editor's follow crop, the framing every clip has (`docs/UIUX.md` § "Clip Detail /
/// Editor"), over the follow harness's take, an athlete crossing a landscape frame
/// (`-screenshotClipEditorFollow`).
final class FollowModeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchEditor(_ arguments: [String] = ["-screenshotClipEditorFollow"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        // Enabled once the editor has its media, as every framing button is.
        let rotate = app.buttons["auto-rotate-button"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 45))
        XCTAssertTrue(
            waitUntil(timeout: 45) { rotate.isEnabled },
            "the editor never loaded its media: \(app.harnessMovieState)")
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// Polls a frame until two reads agree, so a read doesn't land mid-animation.
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var previous = element.frame
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.15)
            let current = element.frame
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    /// A clip opens in Follow on Auto follow's crop, with no mode to switch to: the lane holds
    /// Auto follow's keyframes, the button offers Reset follow, and the marker is Follow's 9:16.
    func testAClipOpensInFollowOnAutoFollow() throws {
        let app = launchEditor()
        XCTAssertFalse(app.segmentedControls["framing-mode-switch"].exists)
        XCTAssertFalse(app.buttons["clip-editor-delete"].exists)
        let follow = app.buttons["auto-follow-button"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { follow.label == "Reset follow" }, "the clip didn't open on Auto follow")
        let lane = element("follow-lane", in: app)
        XCTAssertTrue(lane.waitForExistence(timeout: 5))
        let keyframes = Int((lane.value as? String ?? "").prefix { $0.isNumber }) ?? 0
        XCTAssertGreaterThanOrEqual(keyframes, 2, "lane reads \(lane.value as? String ?? "nothing")")
        let marker = element("crop-marker", in: app)
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        let frame = settledFrame(of: marker)
        XCTAssertEqual(frame.width / frame.height, 9.0 / 16.0, accuracy: 0.01)
    }

    /// Auto follow and Reset follow toggle, and a pinch hands the button back to Auto follow.
    func testFollowsButtonTogglesAndAPinchHandsItBack() throws {
        let app = launchEditor()
        let follow = app.buttons["auto-follow-button"]
        XCTAssertTrue(follow.waitForExistence(timeout: 10))
        XCTAssertEqual(follow.label, "Reset follow", "a clip opening in Follow shows Auto follow's crop")

        follow.tap()
        XCTAssertTrue(waitUntil { follow.label == "Auto follow" })
        let lane = element("follow-lane", in: app)
        XCTAssertTrue(waitUntil { (lane.value as? String ?? "").hasPrefix("0 keyframes") })

        follow.tap()
        XCTAssertTrue(waitUntil { follow.label == "Reset follow" })

        element("clip-editor-crop-surface", in: app).pinch(withScale: 1.4, velocity: 1)
        XCTAssertTrue(waitUntil { follow.label == "Auto follow" }, "a pinch left Auto follow's button on Reset")
    }

    /// A drag on the lane scrubs and pauses: the play button then offers Play, and a second
    /// drag moves the paused playhead. The two scrubs are compared with each other, not with
    /// the playing preview: a drag lands on the same frame whenever it starts, so the frame
    /// playing beforehand can be the one it lands on.
    func testScrubbingTheLanePausesPlayback() throws {
        let app = launchEditor()
        let lane = element("follow-lane", in: app)
        XCTAssertTrue(lane.waitForExistence(timeout: 10))
        let playPause = app.buttons["playback-play-pause"]
        XCTAssertTrue(waitUntil { playPause.label == "Pause" }, "the preview never started playing")

        scrub(lane, from: 0.2, by: 120)
        XCTAssertTrue(waitUntil { playPause.label == "Play" }, "scrubbing the lane didn't pause")
        let scrubbed = lane.value as? String

        scrub(lane, from: 0.85, by: -40)
        XCTAssertTrue(
            waitUntil { lane.value as? String != scrubbed }, "a second scrub left the playhead at \(scrubbed ?? "")")
    }

    private func scrub(_ lane: XCUIElement, from fraction: CGFloat, by points: CGFloat) {
        let start = lane.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: points, dy: 0)),
            withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.1)
    }

    private func keyframeCount(in lane: XCUIElement) -> Int {
        Int((lane.value as? String ?? "").prefix { $0.isNumber }) ?? -1
    }

    /// A one-finger drag in Follow pauses at touch-down and sets the framing at that moment:
    /// the clip stays paused, and the keyframe it set or moved hands Auto follow's button back.
    func testADragInFollowSetsTheFramingAtThePlayhead() throws {
        let app = launchEditor()
        let follow = app.buttons["auto-follow-button"]
        XCTAssertTrue(follow.waitForExistence(timeout: 10))
        XCTAssertEqual(follow.label, "Reset follow")
        let playPause = app.buttons["playback-play-pause"]
        XCTAssertTrue(waitUntil { playPause.label == "Pause" })

        let surface = element("clip-editor-crop-surface", in: app)
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)),
            withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.05)

        XCTAssertTrue(waitUntil { playPause.label == "Play" }, "touch-down in Follow didn't pause")
        XCTAssertTrue(waitUntil { follow.label == "Auto follow" }, "the drag set no keyframe")
    }

    /// The lane's button adds a keyframe at the playhead and then, with one there, removes it.
    /// From Reset follow's empty lane, so the playhead can't already sit on a keyframe.
    func testTheLaneButtonAddsAndRemovesAKeyframe() throws {
        let app = launchEditor()
        let lane = element("follow-lane", in: app)
        XCTAssertTrue(lane.waitForExistence(timeout: 10))
        let follow = app.buttons["auto-follow-button"]
        XCTAssertTrue(waitUntil { follow.label == "Reset follow" })
        follow.tap()
        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 0 })
        lane.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.5)).tap()
        let button = app.buttons["follow-keyframe-button"]
        XCTAssertTrue(waitUntil { button.label == "Add keyframe" })

        button.tap()

        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 1 })
        XCTAssertTrue(waitUntil { button.label == "Remove keyframe" })
        button.tap()
        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 0 })
    }

    /// A pinch in Follow sets the framing at the playhead the way a drag does: from Reset
    /// follow's empty lane, it leaves one keyframe where the playhead is.
    func testAPinchInFollowSetsAKeyframeAtThePlayhead() throws {
        let app = launchEditor()
        let lane = element("follow-lane", in: app)
        XCTAssertTrue(lane.waitForExistence(timeout: 10))
        let follow = app.buttons["auto-follow-button"]
        XCTAssertTrue(waitUntil { follow.label == "Reset follow" })
        follow.tap()
        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 0 })
        lane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        element("clip-editor-crop-surface", in: app).pinch(withScale: 1.5, velocity: 1)

        XCTAssertTrue(
            waitUntil { self.keyframeCount(in: lane) == 1 }, "lane reads \(lane.value as? String ?? "nothing")")
        XCTAssertTrue(waitUntil { app.buttons["follow-keyframe-button"].label == "Remove keyframe" })
    }

    /// A long press on a diamond offers both of its choices: giving every keyframe its zoom and
    /// turn, and removing it.
    func testALongPressOnADiamondOffersApplyToAllAndRemove() throws {
        let app = launchEditor()
        let lane = element("follow-lane", in: app)
        XCTAssertTrue(lane.waitForExistence(timeout: 10))
        let follow = app.buttons["auto-follow-button"]
        XCTAssertTrue(waitUntil { follow.label == "Reset follow" })
        follow.tap()
        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 0 })
        let spot = lane.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        spot.tap()
        app.buttons["follow-keyframe-button"].tap()
        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 1 })

        spot.press(forDuration: 0.9)

        // The dialog's buttons can show up twice in the tree while it presents.
        let apply = app.buttons.matching(identifier: "follow-apply-to-all-button").firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "the long press offered no choices")
        XCTAssertEqual(apply.label, "Apply zoom and turn to all keyframes")
        let remove = app.buttons.matching(identifier: "follow-remove-keyframe-button").firstMatch
        XCTAssertTrue(remove.exists)
        remove.tap()
        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 0 })
    }

    /// Following an athlete who stays put leaves one keyframe and says so: Reset follow, then
    /// Auto follow again over the screenshot harness's standing athlete. The
    /// notice stays up (`-noticesStay`): on its own timer it can be gone before a loaded runner
    /// answers the query.
    func testAnAthleteWhoStaysPutHasNothingToFollow() throws {
        let app = launchEditor(["-screenshotClipEditor", "-noticesStay"])
        let follow = app.buttons["auto-follow-button"]
        XCTAssertTrue(waitUntil { follow.label == "Reset follow" })
        follow.tap()
        XCTAssertTrue(waitUntil { follow.label == "Auto follow" })

        follow.tap()

        XCTAssertTrue(element("nothing-to-follow-notice", in: app).waitForExistence(timeout: 5))
    }

    /// Every crop gesture keeps working after a pinch with no turn in it: the editor once
    /// ignored every drag, pinch and turn that followed one. From Reset follow's empty lane,
    /// each pinch and turn is read off the crop area's accessibility value, which spells out the
    /// zoom and turn at the playhead and has to change; a drag, which the value doesn't spell
    /// out, at a moment of its own has to add a keyframe there.
    func testCropGesturesKeepWorkingAfterAPinch() throws {
        let app = launchEditor()
        let lane = element("follow-lane", in: app)
        XCTAssertTrue(lane.waitForExistence(timeout: 10))
        let follow = app.buttons["auto-follow-button"]
        XCTAssertTrue(waitUntil { follow.label == "Reset follow" })
        follow.tap()
        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 0 })
        lane.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        let surface = element("clip-editor-crop-surface", in: app)
        func framing() -> String { surface.value as? String ?? "" }
        let steps: [(name: String, gesture: () -> Void)] = [
            ("pinch", { surface.pinch(withScale: 0.7, velocity: -1) }),
            ("pinch after the pinch", { surface.pinch(withScale: 1.4, velocity: 1) }),
            ("turn after the pinch", { surface.rotate(0.4, withVelocity: 1) })
        ]
        for step in steps {
            let before = framing()
            step.gesture()
            XCTAssertTrue(
                waitUntil(timeout: 3) { framing() != before },
                "the \(step.name) left the framing at \"\(before)\"")
        }
        XCTAssertTrue(waitUntil { self.keyframeCount(in: lane) == 1 })

        lane.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        // Above the playback pill at the bottom of the marker.
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 80, dy: 0)),
            withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.05)

        XCTAssertTrue(
            waitUntil(timeout: 3) { self.keyframeCount(in: lane) == 2 },
            "the drag after the pinch and turn set no keyframe; lane reads \(lane.value as? String ?? "nothing")")
    }
}
