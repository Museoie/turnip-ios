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
