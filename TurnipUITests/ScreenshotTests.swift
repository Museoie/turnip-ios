import XCTest

/// Screenshot automation for UI-change PRs (CONTRIBUTING.md asks for screenshots
/// on UI changes): launches the app into scripted states via launch arguments
/// (see `ScreenshotHarness.swift`) and captures XCUITest screenshots. Each test
/// prints its PNG as base64 to stdout (TURNIP_SCREENSHOT:<name>:<base64>); the CI
/// screenshots job greps the log and uploads the PNGs as the pr-screenshots
/// artifact, and the screenshots-comment workflow posts them on the PR — so
/// nobody needs a local simulator to produce PR screenshots.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Export confirmation mid-run: first clip at 50%, second waiting.
    func testExportConfirmationProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotExportConfirmation"]
        app.launch()
        // The row sets an explicit combined accessibilityLabel ("Clip 1 · 3s,
        // exporting, 50 percent"), so the ProgressView's own "Exporting…" text is
        // never exposed as its own element — match the row's label instead.
        let exportingRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'exporting'"))
            .firstMatch
        XCTAssertTrue(exportingRow.waitForExistence(timeout: 15))
        addScreenshot(named: "export-confirmation-progress")
    }

    /// Export confirmation after the run: "2 of 2 clips saved to Photos".
    func testExportConfirmationSummary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotExportConfirmationFinished"]
        app.launch()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 15))
        addScreenshot(named: "export-confirmation-summary")
    }

    /// The Share action on a saved clip opens the system share sheet — the whole of
    /// issue 12's publish story. Drives the real affordance (tap the row's Share
    /// button), not a direct presentation, and screenshots the sheet.
    func testExportConfirmationShareSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotExportConfirmationFinished"]
        app.launch()
        let shareButton = app.buttons["Share"].firstMatch
        XCTAssertTrue(shareButton.waitForExistence(timeout: 15))
        // A Share action over a missing file disables itself, so an enabled button is
        // also the assertion that the run left a real file behind for it.
        XCTAssertTrue(shareButton.isEnabled)
        shareButton.tap()

        // `UIActivityViewController` exposes its container as `ActivityListView`.
        // The fallback covers the identifier changing under us: the sheet is modal,
        // so the button that opened it stops being hittable once it is up.
        let activitySheet = app.otherElements["ActivityListView"]
        let sheetIsUp = activitySheet.waitForExistence(timeout: 15) || !shareButton.isHittable
        XCTAssertTrue(sheetIsUp, "tapping Share did not present the system share sheet")
        addScreenshot(named: "export-confirmation-share-sheet")
    }

    /// Home's Photos-denied empty state: the only Home state scriptable without the
    /// Photos library (the grid needs real PHAssets, which have no public
    /// initializer, and the real HomeView would raise the system permission prompt).
    func testHomeAccessDenied() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotHome"]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Turnip needs access to your videos"]
                .waitForExistence(timeout: 15))
        addScreenshot(named: "home-access-denied")
    }

    /// Clip list triage: three detected windows, one discarded, thumbnails as
    /// placeholder tiles (the /dev/null asset decodes nothing; the loader falls
    /// back to the placeholder — the test waits for the placeholder's
    /// accessibility element, so it guards the fallback and not just the
    /// navigation bar appearing).
    func testClipListTriage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipList"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let placeholder = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Thumbnail placeholder'"))
            .firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 15))
        addScreenshot(named: "clip-list-triage")
    }

    /// Clip editor over a generated sample movie: the preview with the live crop
    /// rect, the trim slider, and the keep toggle. The trim range's accessibility
    /// label ("Trim range 2.0s to 5.0s") only appears once the movie's duration
    /// loads, so it also proves the editor reached its loaded state.
    func testClipEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipEditor"]
        app.launch()
        let trimRange = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Trim range 2.0s to 5.0s'"))
            .firstMatch
        XCTAssertTrue(trimRange.waitForExistence(timeout: 15))
        addScreenshot(named: "clip-editor")
    }

    /// Processing mid-run: the stub runner reports "Analyzing frame 400 of 1200"
    /// and holds the run open (the test runner kills the app before the hold
    /// expires). No inference, no model, no video file.
    func testProcessingProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessing"]
        app.launch()
        let progress = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Analysis progress'"))
            .firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        addScreenshot(named: "processing-progress")
    }

    /// Pose diagnostic before a run: the video length and the "Run diagnostic"
    /// button. No inference runs until the button is tapped, so the initial state
    /// needs neither the model nor a real video file.
    func testPoseDiagnosticInitial() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotPoseDiagnostic"]
        app.launch()
        XCTAssertTrue(app.buttons["Run diagnostic"].waitForExistence(timeout: 15))
        addScreenshot(named: "pose-diagnostic")
    }

    private func addScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Print base64 PNG to stdout for CI extraction (env vars don't propagate
        // to the test runner, and xcresult parsing is fragile).
        // The workflow greps for TURNIP_SCREENSHOT:<name>:<base64>.
        let b64 = screenshot.pngRepresentation.base64EncodedString()
        print("TURNIP_SCREENSHOT:\(name):\(b64)")
    }
}
