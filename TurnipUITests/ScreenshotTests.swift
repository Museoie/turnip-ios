import XCTest

/// Screenshot automation for UI-change PRs (CONTRIBUTING.md asks for screenshots
/// on UI changes): launches the app into scripted states via launch arguments
/// (see `ScreenshotHarness.swift`) and captures XCUITest screenshots. The
/// screenshots workflow extracts them from the xcresult and uploads them as an
/// artifact, so nobody needs a local simulator to produce PR screenshots.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Export confirmation mid-run: first clip at 50%, second waiting.
    func testExportConfirmationProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotExportConfirmation"]
        app.launch()
        // The row sets an explicit combined accessibilityLabel ("Clip 1 · 2.4s,
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

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
