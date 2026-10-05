import XCTest

/// Scratch verification for the sizing/fade fixes in `docs/EXPANSION_TRANSITIONS.md` Rev 2.
/// Not wired into CI — run manually while debugging this feature. Reads `"expansion-card"`'s
/// laid-out frame via the accessibility tree (reported independent of its current opacity)
/// rather than screenshots/pixels, since that gives an exact rect instead of a color guess.
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
