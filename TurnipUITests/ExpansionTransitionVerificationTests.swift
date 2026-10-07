import XCTest

/// Verification of the expansion transitions in `docs/EXPANSION_TRANSITIONS.md`: the
/// containers' geometry, and what their close paths hand back. Runs with the rest of
/// `TurnipUITests` in the scheme's test action, so CI's `xcodebuild test` covers it. Reads
/// element frames via the accessibility tree (reported independent of an element's current
/// opacity) rather than screenshots/pixels, since that gives an exact rect instead of a
/// color guess.
final class ExpansionTransitionVerificationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Polls `element.frame` until two consecutive reads agree, rather than a fixed sleep —
    /// the spring settles in well under a second, but a fixed sleep risks sampling mid-flight
    /// on a loaded CI runner.
    private func settledFrame(of element: XCUIElement, timeout: TimeInterval = 5) -> CGRect {
        var previous = element.frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            let current = element.frame
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    /// `HomeExpansionContainer.fallbackDestination` with a known non-square
    /// `initialAspectRatio` and a `content` that never reports a measurement — isolates
    /// exactly the code path Rev 2 changed from a blind full-screen rect to an
    /// `AVMakeRect`-letterboxed one. If this regresses to the full screen, the card's
    /// settled height will be close to the whole window instead of a letterboxed band.
    func testHomeExpansionFallbackDestinationLetterboxesInsteadOfFullScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotHomeExpansion"]
        app.launch()
        let card = app.descendants(matching: .any).matching(identifier: "expansion-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let windowHeight = app.windows.firstMatch.frame.height
        let cardFrame = settledFrame(of: card)
        print("VERIFY_HOME_CARD_FRAME:\(cardFrame)")
        print("VERIFY_HOME_WINDOW_HEIGHT:\(windowHeight)")
        XCTAssertLessThan(
            cardFrame.height, windowHeight * 0.6,
            "card settled near the full window height — the fallback regressed to full screen")
    }

    /// `ClipExpansionContainer`'s destination measurement, over the real
    /// `-screenshotClipListMedia` flow `testClipListTapOpensEditor` already exercises for
    /// reachability. At `progress == 1` the card's `rect` always exactly equals whatever
    /// `destination` resolved to (by `currentRect`'s own lerp), so comparing the settled,
    /// invisible-but-still-laid-out card frame against the real preview's independently
    /// reported accessibility frame proves whether `measuredDestination` converged to the
    /// true frame or stayed stuck on the old placeholder square (`x:16,y:100`, `screenWidth-32`
    /// wide) that the removed `progress > 0.98` gate used to leave it on.
    func testClipExpansionOpenConvergesToTheEditorsRealPreviewFrame() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Open clip'"))
            .firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.tap()
        XCTAssertTrue(app.staticTexts["clip-editor-title"].waitForExistence(timeout: 15))

        let preview = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Clip preview with crop area'"))
            .firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let card = app.descendants(matching: .any).matching(identifier: "expansion-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        let previewFrame = settledFrame(of: preview)
        let cardFrame = settledFrame(of: card)
        print("VERIFY_CLIP_PREVIEW_FRAME:\(previewFrame)")
        print("VERIFY_CLIP_CARD_FRAME:\(cardFrame)")
        XCTAssertEqual(cardFrame.minX, previewFrame.minX, accuracy: 2)
        XCTAssertEqual(cardFrame.minY, previewFrame.minY, accuracy: 2)
        XCTAssertEqual(cardFrame.width, previewFrame.width, accuracy: 2)
        XCTAssertEqual(cardFrame.height, previewFrame.height, accuracy: 2)
    }

    /// The editor's own top row (`ScreenHeaderBand`) against the clip list's titled bar it
    /// flies open from: the back chevron and the title cross-fade over the list's through
    /// the flight, so they have to sit at the same height, with the title at the same
    /// center, or the header visibly jumps at the cut. Compares the two screens' element
    /// frames in one flow, on whichever OS the run is on — the band's metrics branch per OS.
    func testClipEditorHeaderLinesUpWithTheClipListsBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let listBack = settledFrame(of: app.buttons["Back to Home"].firstMatch)
        let listTitle = settledFrame(of: app.navigationBars["Clips"].staticTexts["Clips"].firstMatch)
        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Open clip'"))
            .firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.tap()
        let editorTitle = app.staticTexts["clip-editor-title"]
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 15))
        let editorBack = settledFrame(of: app.buttons["Back to clips"].firstMatch)
        let editorTitleFrame = settledFrame(of: editorTitle)
        print("VERIFY_LIST_BACK:\(listBack) VERIFY_EDITOR_BACK:\(editorBack)")
        print("VERIFY_LIST_TITLE:\(listTitle) VERIFY_EDITOR_TITLE:\(editorTitleFrame)")
        XCTAssertEqual(editorBack.midY, listBack.midY, accuracy: 1)
        XCTAssertEqual(editorTitleFrame.midY, listTitle.midY, accuracy: 1)
        XCTAssertEqual(editorTitleFrame.midX, listTitle.midX, accuracy: 1)
        // Both are the same `ScrimIconButton` circle, the list's with the bar's own wider
        // pill hidden under it, so the frames match outright, not just the glyph.
        XCTAssertEqual(editorBack.midX, listBack.midX, accuracy: 1)
        XCTAssertEqual(editorBack.size.width, listBack.size.width, accuracy: 1)
        XCTAssertEqual(editorBack.size.height, listBack.size.height, accuracy: 1)
    }

    /// Swipe-to-dismiss is the editor's back-navigation by another route, so it has to hand
    /// the edits back the way the back chevron does: trim the clip, swipe down from the
    /// header band, and the tile's caption must show the new duration. The harness's two
    /// clips both start at 1.5s; dragging the end handle right lengthens the first one.
    func testSwipeToDismissCommitsTheEdit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["1.5s"].firstMatch.waitForExistence(timeout: 15))
        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Open clip'"))
            .firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.tap()
        XCTAssertTrue(app.staticTexts["clip-editor-title"].waitForExistence(timeout: 15))
        let trimEnd = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Trim end'"))
            .firstMatch
        // Longer than the usual wait: the handle only exists once the sample movie's
        // duration has loaded, the same real wall-clock work `testClipEditor` waits on.
        XCTAssertTrue(trimEnd.waitForExistence(timeout: 45))
        Thread.sleep(forTimeInterval: 1)
        // Strictly horizontal: vertical travel slows the handle (`ScrubCalculator`).
        let grab = trimEnd.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(
            forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: 80, dy: 0)),
            withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.2)
        let trimmed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Trim range'"))
            .firstMatch
        XCTAssertTrue(trimmed.waitForExistence(timeout: 5))
        XCTAssertNotEqual(trimmed.label, "Trim range 0.5s to 2.0s", "the drag didn't move the end handle")

        // Down from the title itself — the top row's band, which the dismiss gesture owns
        // (the video surface keeps a downward drag for its own crop gesture) — so the
        // start point doesn't depend on the device's status-bar height.
        let start = app.staticTexts["clip-editor-title"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 550)),
            withVelocity: XCUIGestureVelocity(900), thenHoldForDuration: 0.05)
        // `ClipExpansionContainer.dismissAfterLanding` disables UIKit animations for ~0.5s
        // after the flight, during which accessibility queries can't complete — wait it out.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 10))
        let captions = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES '[0-9.]+s'"))
            .allElementsBoundByIndex.map(\.label)
        print("VERIFY_CAPTIONS_AFTER_SWIPE:\(captions)")
        XCTAssertEqual(captions.count, 2)
        XCTAssertTrue(captions.contains { $0 != "1.5s" }, "the swipe-dismissed edit never reached the tile")
    }

    // A close-direction counterpart (sampling the card mid-flight after tapping "Back to
    // clips") was attempted here and dropped: `ClipExpansionContainer.close()` calls
    // `UIView.setAnimationsEnabled(false)` globally for the ~0.42s–0.92s window after a close
    // begins (see its own doc comment — this is deliberate, suppressing the system's dismiss
    // animation), and XCUITest's accessibility snapshot query cannot be completed while that's
    // in effect — reproducible even across a simulator reboot, not a flake. `close()` reads
    // the same `measuredDestination` this file's open test already proved converges to the
    // real frame, through the same unchanged `currentRect`/`sourceFrame`, so the close
    // direction has no separate computation left to doubt; it just isn't independently
    // observable through this harness's accessibility tree.
}
