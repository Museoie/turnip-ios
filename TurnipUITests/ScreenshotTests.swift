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

    /// Home's Photos-denied empty state, one of the Home states scriptable without the
    /// Photos library -- a populated grid isn't, since it needs real PHAssets, which have
    /// no public initializer, and the real HomeView fetching would raise the system
    /// permission prompt (see testGalleryFilterMenuOpen below for another such state).
    func testHomeAccessDenied() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotHome"]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Turnip needs access to your videos"]
                .waitForExistence(timeout: 15))
        addScreenshot(named: "home-access-denied")
    }

    /// Guards the settings gear's touch target with a real synthesized touch, not just its
    /// presence or `isHittable` — `waitForExistence` (what `testHomeAccessDenied` above
    /// checks) is true whether or not a real tap can reach the element, and `isHittable`'s
    /// exact fidelity against a system `UINavigationBar` occluder is itself unverified on
    /// this machine (no Xcode/simulator to test XCTest's own hit-testing semantics against).
    /// `.tap()` sends a real touch through UIKit's actual dispatch and asserting the sheet it
    /// opens is the one thing a presence/hittability check cannot prove: that this exact
    /// button, wired to its real action (not a no-op), is reachable end to end.
    func testHomeSettingsButtonOpensSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotHome"]
        app.launch()
        let button = app.buttons["settings-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
    }

    /// The filter button's neighbor in the same top-trailing overlay, in the denied-access Home
    /// state (a populated grid is what's actually unscriptable without real Photos access — see
    /// `testGalleryFilterMenuOpen` below for another state that sidesteps that the same way).
    /// Here `GalleryFilterButton` is deliberately dimmed and `.disabled` rather than hidden
    /// (`HomeView.swift`) — a Favorites
    /// tap that silently changed nothing while access is denied would be worse than an
    /// unavailable control. A real synthesized touch is the only way to prove `.disabled`
    /// actually blocks the menu rather than just looking dimmed: `isEnabled` alone doesn't show
    /// whether a `Menu` still opens under a real tap, the same reason
    /// `testHomeSettingsButtonOpensSettings` above taps rather than trusting presence.
    func testGalleryFilterButtonIsDisabledWithoutPhotosAccess() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotHome"]
        app.launch()
        let button = app.buttons["gallery-filter-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        XCTAssertFalse(button.isEnabled)
        button.tap()
        XCTAssertFalse(app.buttons["All Items"].waitForExistence(timeout: 2))
    }

    /// The actual filter feature, open (`-screenshotGalleryFilter`, CONTRIBUTING.md's
    /// screenshots-on-UI-change ask) — the button being present-but-disabled above doesn't show
    /// what the feature itself looks like. "All Items" carries a checkmark as the default
    /// selection; asserting on it (not just the button) proves the menu's real content rendered.
    func testGalleryFilterMenuOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotGalleryFilter"]
        app.launch()
        let button = app.buttons["gallery-filter-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        XCTAssertTrue(app.buttons["All Items"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Favorites"].exists)
        addScreenshot(named: "gallery-filter-menu")
    }

    /// Clip list triage: three detected windows, one trashed, thumbnails as
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

    /// Clip list over real media: the `/dev/null` asset in `testClipListTriage` never
    /// loads a duration, so its tiles' read-only range timeline stays hidden behind its
    /// `if let duration` guard — this proves the timeline actually renders once the
    /// asset loads for real.
    func testClipListMedia() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let rangeTimeline = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Clip from'"))
            .firstMatch
        XCTAssertTrue(rangeTimeline.waitForExistence(timeout: 15))
        addScreenshot(named: "clip-list-media")
    }

    /// Trashing the original tile flips its icon button's accessibility label rather
    /// than removing it, and the screen carries no leftover select-all affordance —
    /// the triage screen's toolbar has only the back chevron, and "Save Clips" is
    /// the screen's action. The original tile is always the first of the
    /// grid's "Trash clip" buttons, since `ClipListViewModel` prepends it to `items`.
    func testTrashButtonTogglesToRestoreOnTheOriginalTile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let trashButtons = app.buttons.matching(NSPredicate(format: "label == 'Trash clip'"))
        let originalTrashButton = trashButtons.element(boundBy: 0)
        XCTAssertTrue(originalTrashButton.waitForExistence(timeout: 15))
        originalTrashButton.tap()

        XCTAssertTrue(app.buttons["Restore clip"].firstMatch.waitForExistence(timeout: 5))
        // The dimmed tile says in words what trashing the original means.
        XCTAssertTrue(app.staticTexts["original-deletion-notice"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["original-deletion-notice"].label, "Will be deleted")
        XCTAssertFalse(app.buttons["Select All"].exists)
        XCTAssertFalse(app.buttons["Deselect All"].exists)
        XCTAssertTrue(app.buttons["Save Clips"].exists)
        addScreenshot(named: "clip-list-original-trashed")
    }

    /// A derived clip's trash button removes its tile from the grid outright (a 150ms
    /// fade-and-reflow, which the poll below outlasts), unlike the original tile's
    /// reversible toggle above — no "Restore clip" label ever appears for it.
    func testTrashButtonRemovesADerivedClipImmediately() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Clips"].waitForExistence(timeout: 15))
        let trashButtons = app.buttons.matching(NSPredicate(format: "label == 'Trash clip'"))
        XCTAssertEqual(trashButtons.count, 3) // original tile + two derived clips
        let derivedTrashButton = trashButtons.element(boundBy: 1)
        XCTAssertTrue(derivedTrashButton.waitForExistence(timeout: 15))
        derivedTrashButton.tap()

        // Waits for the "Trash clip" count to actually settle at 2 before checking
        // for "Restore clip": asserting immediately after `.tap()`, before SwiftUI
        // re-renders, would pass under either implementation — the toggle bug drops
        // this same count by relabeling one button to "Restore clip", not by
        // removing it. Only once the count has settled does the absence of
        // "Restore clip" distinguish outright removal from a relabel.
        let deadline = Date().addingTimeInterval(5)
        while trashButtons.count != 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(trashButtons.count, 2)
        XCTAssertFalse(app.buttons["Restore clip"].exists)
    }

    /// Auto crop and Auto rotate are toggles: each tap puts its fit on screen and the same
    /// button then offers to put back what the fit replaced, independently of the other.
    /// Auto rotate levels the harness clip by the roll track its sample movie carries, so
    /// this also proves the track reader works inside the app, not just in the unit tests.
    func testClipEditorAutoFitsToggleToResets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipEditor"]
        app.launch()
        waitForClipEditorToLoad(app)
        let crop = app.buttons["auto-crop-button"]
        let rotate = app.buttons["auto-rotate-button"]
        XCTAssertTrue(waitUntilHittable(crop))
        XCTAssertEqual(crop.label, "Auto crop")
        XCTAssertEqual(rotate.label, "Auto rotate")

        crop.tap()
        XCTAssertTrue(waitUntil { crop.label == "Reset crop" }, "Auto crop did not become Reset crop")
        XCTAssertEqual(rotate.label, "Auto rotate")

        rotate.tap()
        XCTAssertTrue(waitUntil { rotate.label == "Reset rotate" }, "Auto rotate did not become Reset rotate")
        XCTAssertEqual(crop.label, "Reset crop")
        // The fit moves the video over 0.4 s; the screenshot is of the settled result.
        Thread.sleep(forTimeInterval: 1)
        addScreenshot(named: "clip-editor-resets")

        crop.tap()
        XCTAssertTrue(waitUntil { crop.label == "Auto crop" }, "Reset crop did not return to Auto crop")
        XCTAssertEqual(rotate.label, "Reset rotate", "resetting the crop must leave the rotate button alone")
    }

    /// Waits for the clip editor harness to reach its loaded state (the trim range label),
    /// failing fast with a reason if its sample movie failed to encode — see `testClipEditor`.
    private func waitForClipEditorToLoad(_ app: XCUIApplication) {
        let trimRange = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Trim range 2.0s to 5.0s'"))
            .firstMatch
        let loadFailure = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn't load this clip"))
            .firstMatch
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !trimRange.exists {
            XCTAssertFalse(
                loadFailure.exists,
                "editor reached its load-failure state: the harness's sample movie failed to encode")
            if loadFailure.exists { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(trimRange.exists, "the editor never reached its loaded state")
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// Tapping a tile opens the full `ClipEditorView` directly — the tile itself is
    /// the single entry point into detail/editing, not a separate expand icon and not
    /// an intermediate full-screen viewer.
    func testClipListTapOpensEditor() throws {
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
        addScreenshot(named: "clip-list-expand-to-editor")
    }

    /// Clip editor over a generated sample movie: the preview with the live crop
    /// rect and the trim slider. The trim range's accessibility
    /// label ("Trim range 2.0s to 5.0s") only appears once the movie's duration
    /// loads, so it also proves the editor reached its loaded state.
    ///
    /// The wait is longer than this file's usual 15s: unlike every other wait
    /// here, which is on SwiftUI state already computed in memory, this element
    /// waits on `ScreenshotClipEditorHarness`'s `AVAssetWriter` encode plus the
    /// player's async duration load — real wall-clock work whose duration swings
    /// with host CPU contention on a shared CI runner.
    func testClipEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipEditor"]
        app.launch()
        let trimRange = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Trim range 2.0s to 5.0s'"))
            .firstMatch
        // Fail fast, and with a reason, if the harness degraded to its load-failure
        // fallback: without this, a sample-movie encode that failed on a loaded CI
        // runner (see `ScreenshotHarness.appendSolidFrame`) showed up only as this
        // wait silently running out its full 45s — indistinguishable from "slow".
        let loadFailure = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn't load this clip"))
            .firstMatch
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !trimRange.exists {
            XCTAssertFalse(
                loadFailure.exists,
                "editor reached its load-failure state: the harness's sample movie failed to encode")
            if loadFailure.exists { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(trimRange.exists, "trim range never loaded within 45s")
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

    /// Processing's resting state: the picked video full-screen with the custom scrub
    /// bar and the "Analyze clips" button — no native `VideoPlayer` chrome and no
    /// caption text.
    func testProcessingIdle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingIdle"]
        app.launch()
        XCTAssertTrue(app.buttons["Analyze clips"].waitForExistence(timeout: 15))
        addScreenshot(named: "processing-idle")
    }

    /// "Clip manually" pushes the clip list destination straight from the idle state, with
    /// the result marked as skipped — the real `navigationDestination` binding flip, not
    /// just the view model's state.
    func testProcessingSkipAnalysisPushesTheClipList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingIdle"]
        app.launch()
        let skip = app.buttons["Clip manually"]
        XCTAssertTrue(skip.waitForExistence(timeout: 15))
        skip.tap()
        let standIn = app.staticTexts["clip-list-stand-in"]
        XCTAssertTrue(standIn.waitForExistence(timeout: 15), "the skip never pushed the destination")
        XCTAssertEqual(standIn.label, "Clip list stand-in: skipped")
    }

    /// A swipe on Processing browses to the neighboring video — the whole page follows the
    /// finger and the neighbor lands — rather than paging the app's Camera/Home container
    /// or doing nothing. Driven with real synthesized drags against the harness's page
    /// `TabView`, because that pager's UIKit recognizer is exactly what no gesture priority
    /// in SwiftUI can beat, and only a real touch exercises it. The harness's stand-in
    /// videos carry solid red/green/blue posters, so the screen's center color says which
    /// one is showing; the stand-in Camera page is gray, so a swipe that reached the pager
    /// reads as neither.
    func testProcessingSwipeBrowsesNeighborsInsteadOfPaging() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingBrowse"]
        app.launch()
        XCTAssertTrue(app.buttons["Analyze clips"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitForCenterColor(.green), "did not start on the middle (green) stand-in video")

        // Left, from the middle of the screen: the next (blue) video.
        drag(app, fromX: 0.7, toX: 0.05, y: 0.5)
        XCTAssertTrue(waitForCenterColor(.blue), "left swipe did not land on the next video")
        XCTAssertTrue(waitUntilHittable(app.buttons["Analyze clips"]), "the landed screen's controls never arrived")

        // Right, starting at the leading edge where the navigation stack's edge-pop would
        // otherwise claim it: back to green.
        drag(app, fromX: 0.01, toX: 0.7, y: 0.5)
        XCTAssertTrue(waitForCenterColor(.green), "right swipe from the leading edge did not land on the previous")

        // Right, from the top band under the status bar: the previous (red) video.
        drag(app, fromX: 0.5, toX: 0.98, y: 0.09)
        XCTAssertTrue(waitForCenterColor(.red), "right swipe from the top band did not land on the previous video")

        // Right again at the newest end of the grid: nothing that way, and in particular
        // not the Camera page.
        drag(app, fromX: 0.3, toX: 0.95, y: 0.5)
        sleep(1)
        XCTAssertTrue(waitForCenterColor(.red), "right swipe at the end of the grid left the video")
        XCTAssertTrue(waitUntilHittable(app.buttons["Analyze clips"]), "the screen's controls did not settle")
        addScreenshot(named: "processing-browse")
    }

    /// Settings sheet at its defaults: the analysis-mode segmented control, the
    /// auto-add-album toggle, and the granularity stepper.
    func testSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotSettings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.segmentedControls["settings-analysis-mode"].waitForExistence(timeout: 15))
        addScreenshot(named: "settings")
    }

    private func drag(_ app: XCUIApplication, fromX: CGFloat, toX: CGFloat, y: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: y))
        start.press(
            forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(900),
            thenHoldForDuration: 0.05)
    }

    /// The neighbor's poster is on screen a beat before the screen that owns it replaces the
    /// one that slid away, so a color check alone can pass while the landed controls are
    /// still a frame or two out.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    private enum Primary {
        case red, green, blue
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    /// Polls the screen's center pixel until its dominant channel is `primary` — the slide
    /// and the landing take a moment, and a fixed sleep is either wasted or too short on a
    /// loaded runner.
    private func waitForCenterColor(_ primary: Primary, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let pixel = centerPixel() {
                let (red, green, blue) = (Int(pixel.red), Int(pixel.green), Int(pixel.blue))
                let dominant: Primary? = red > green + 60 && red > blue + 60 ? .red
                    : green > red + 60 && green > blue + 60 ? .green
                    : blue > red + 60 && blue > green + 60 ? .blue
                    : nil
                if dominant == primary { return true }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    private func centerPixel() -> Pixel? {
        guard let image = XCUIScreen.main.screenshot().image.cgImage,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * (image.bitsPerPixel / 8)
        return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2])
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
