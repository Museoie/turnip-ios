import XCTest

/// Screenshot automation for UI-change PRs (CONTRIBUTING.md asks for screenshots
/// on UI changes): launches the app into scripted states via launch arguments
/// (see `ScreenshotHarness.swift`) and captures XCUITest screenshots. Each test
/// prints its PNG as base64 to stdout (TURNIP_SCREENSHOT:<name>:<base64>), so
/// screenshots can be captured from a local simulator run.
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
    /// back to the placeholder — the test waits for the placeholder clause of a
    /// card's accessibility label, so it guards the fallback and not just the
    /// navigation bar appearing).
    func testClipListTriage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipList"]
        app.launch()
        XCTAssertTrue(app.navigationBars["1 of 3"].waitForExistence(timeout: 15))
        let placeholder = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'thumbnail placeholder'"))
            .firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 15))
        addScreenshot(named: "clip-list-triage")
    }

    /// Name Clips over real media: the `/dev/null` asset in `testClipListTriage` never
    /// loads a duration, so its card's read-only range timeline stays hidden behind its
    /// `if let duration` guard — this proves the timeline actually renders once the
    /// asset loads for real. The card is one accessibility element, and carries the
    /// timeline's words as its value.
    func testClipListMedia() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["1 of 2"].waitForExistence(timeout: 15))
        let rangeTimeline = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH 'Clip from'"))
            .firstMatch
        XCTAssertTrue(rangeTimeline.waitForExistence(timeout: 15))
        addScreenshot(named: "clip-list-media")
    }

    /// The header's "More" menu removes the clip on screen outright, with no restore: the pager
    /// counts one clip fewer and the one after it takes its place. The menu holds nothing about
    /// the original video, and the card carries no trash button of its own.
    func testMoreMenuRemovesTheClipOnScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["1 of 2"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "clip-card-1").firstMatch
            .waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons.matching(identifier: "name-clips-trash").firstMatch.exists)
        let more = app.buttons["name-clips-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertFalse(app.buttons["Delete original after saving"].exists)
        let remove = app.buttons["Remove this clip"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        addScreenshot(named: "name-clips-more-menu")
        remove.tap()

        XCTAssertTrue(app.navigationBars["1 of 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Restore clip"].exists)
    }

    /// The bottom bar pages: the first clip has Next and no Previous, the last has Previous and
    /// "Save Clips" in Next's corner, and each button lands on its neighbor.
    func testNameClipsBarPagesAndSavesOnTheLastClip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["1 of 2"].waitForExistence(timeout: 15))
        let previous = app.buttons["name-clips-previous"].firstMatch
        let next = app.buttons["name-clips-next"].firstMatch
        let save = app.buttons["name-clips-save"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "Next")
        XCTAssertFalse(previous.exists, "the first clip offers Previous")
        XCTAssertFalse(save.exists, "the first clip of two offers Save Clips")
        let nextFrame = next.frame

        next.tap()
        XCTAssertTrue(app.navigationBars["2 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "Save Clips")
        XCTAssertEqual(save.frame.maxX, nextFrame.maxX, accuracy: 1, "Save Clips left Next's corner")
        XCTAssertTrue(previous.exists)
        XCTAssertLessThan(previous.frame.midX, app.frame.midX, "Previous isn't on the leading side")
        XCTAssertTrue(waitUntil { !next.exists }, "the last clip still offers Next")
        addScreenshot(named: "name-clips-last")

        previous.tap()
        XCTAssertTrue(app.navigationBars["1 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { !previous.exists }, "Previous stayed on the first clip")
    }

    /// The keyboard sets the bottom bar aside and the page keeps every naming control above it,
    /// who's in it included; Return adds a name and keeps the keyboard, and Return on an empty
    /// field puts it away and brings the bar back.
    func testTheKeyboardSetsTheBarAsideAndKeepsTheNamingControlsInView() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["1 of 2"].waitForExistence(timeout: 15))
        let primary = app.buttons["name-clips-next"].firstMatch
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        let field = try XCTUnwrap(
            app.textFields.matching(identifier: "name-clips-field").allElementsBoundByIndex.first { $0.isHittable })

        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { !primary.exists }, "the bar stayed over the keyboard")
        func whoIsIn() -> XCUIElement? {
            app.segmentedControls.matching(identifier: "name-clips-who").allElementsBoundByIndex
                .first { $0.frame.minX >= 0 && $0.frame.maxX <= app.frame.maxX }
        }
        XCTAssertTrue(
            waitUntil { (whoIsIn()?.frame.maxY ?? .infinity) <= keyboard.frame.minY },
            "who's in it is under the keyboard")
        addScreenshot(named: "name-clips-keyboard")

        field.typeText("cork\n")
        XCTAssertTrue(app.descendants(matching: .any)["name-clips-names"].waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.exists, "Return on a name put the keyboard away")
        XCTAssertFalse(primary.exists)
        XCTAssertTrue(waitUntil { (whoIsIn()?.frame.maxY ?? .infinity) <= keyboard.frame.minY })

        field.typeText("\n")
        XCTAssertTrue(waitUntil { !keyboard.exists }, "Return on an empty field kept the keyboard")
        XCTAssertTrue(primary.waitForExistence(timeout: 5), "the bar didn't come back")
    }

    /// Auto follow and Auto rotate are toggles: each tap puts its fit on screen and the same
    /// button then offers to put back what the fit replaced, independently of the other. The
    /// clip opens on Auto follow's crop. Auto rotate levels the harness clip by the roll track
    /// its sample movie carries, so this also proves the track reader works inside the app,
    /// not just in the unit tests.
    func testClipEditorAutoFitsToggleToResets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipEditor"]
        app.launch()
        waitForClipEditorToLoad(app)
        let follow = app.buttons["auto-follow-button"]
        let rotate = app.buttons["auto-rotate-button"]
        XCTAssertTrue(waitUntilHittable(follow))
        XCTAssertTrue(waitUntil { follow.label == "Reset follow" }, "the clip didn't open on Auto follow")
        XCTAssertEqual(rotate.label, "Auto rotate")

        rotate.tap()
        XCTAssertTrue(waitUntil { rotate.label == "Reset rotate" }, "Auto rotate did not become Reset rotate")
        XCTAssertEqual(follow.label, "Reset follow")
        // The fit moves the video over 0.4 s; the screenshot is of the settled result.
        Thread.sleep(forTimeInterval: 1)
        addScreenshot(named: "clip-editor-resets")

        follow.tap()
        XCTAssertTrue(waitUntil { follow.label == "Auto follow" }, "Reset follow did not return to Auto follow")
        XCTAssertEqual(rotate.label, "Reset rotate", "resetting the follow crop must leave the rotate button alone")
    }

    /// What a test that lands on the editor's load-failure state reports.
    private func sampleMovieFailureMessage(in app: XCUIApplication) -> String {
        "editor reached its load-failure state: \(app.harnessMovieState)"
    }

    /// Waits for the clip editor harness to reach its loaded state (the trim range label),
    /// failing fast with a reason if its sample movie failed to encode — see `testClipEditor`.
    private func waitForClipEditorToLoad(_ app: XCUIApplication) {
        let trimRange = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Trim range 2 seconds to 5 seconds'"))
            .firstMatch
        let loadFailure = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Couldn't load this clip"))
            .firstMatch
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !trimRange.exists {
            if loadFailure.exists {
                XCTFail(sampleMovieFailureMessage(in: app))
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(trimRange.exists, "the editor never reached its loaded state: \(app.harnessMovieState)")
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// Tapping the clip's card opens the full `ClipEditorView` directly — the card itself is
    /// the single entry point into editing, not a separate expand icon. Reached by identifier
    /// rather than by label, since a card's label counts off its position and duration.
    func testClipListTapOpensEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["1 of 2"].waitForExistence(timeout: 15))
        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'clip-card-1'"))
            .firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        tile.tap()
        XCTAssertTrue(app.staticTexts["clip-editor-title"].waitForExistence(timeout: 15))
        addScreenshot(named: "clip-list-expand-to-editor")
    }

    /// A card whose video is already in Photos says so, and tapping the saved badge's corner
    /// still opens the editor: `testClipListTapOpensEditor` above taps the card's centre, so
    /// it cannot see a dead zone in the corner — and a decorative overlay sibling is
    /// hit-testable by default, which is what would create one. The badge sits 8 pt in from
    /// the card's top-leading corner, 32 pt across.
    func testSavedBadgeRendersAndLeavesItsCornerTappable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotClipListMedia"]
        app.launch()
        XCTAssertTrue(app.navigationBars["1 of 2"].waitForExistence(timeout: 15))
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'clip-card-1' AND label CONTAINS 'saved to Photos'"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 24)).tap()
        XCTAssertTrue(app.staticTexts["clip-editor-title"].waitForExistence(timeout: 15))
    }

    /// Clip editor over a generated sample movie: the preview with the live crop
    /// rect and the trim slider. The trim range's accessibility
    /// label ("Trim range 2 seconds to 5 seconds") only appears once the movie's duration
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
            .matching(NSPredicate(format: "label == 'Trim range 2 seconds to 5 seconds'"))
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
            if loadFailure.exists {
                XCTFail(sampleMovieFailureMessage(in: app))
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(trimRange.exists, "trim range never loaded within 45s: \(app.harnessMovieState)")
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
    /// bar and "Clip it" in the top-trailing corner — no native `VideoPlayer` chrome, no
    /// caption text, and no analyze button of its own.
    func testProcessingIdle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingIdle"]
        app.launch()
        let clipIt = app.buttons["processing-clip-it"]
        XCTAssertTrue(clipIt.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(clipIt.frame.midX, app.frame.midX, "Clip it isn't in the trailing corner")
        XCTAssertLessThan(clipIt.frame.midY, app.frame.midY, "Clip it isn't at the top")
        XCTAssertFalse(app.buttons["Analyze clips"].exists)
        XCTAssertFalse(app.buttons["Clip manually"].exists)
        XCTAssertFalse(
            app.segmentedControls["person-mode-picker"].exists, "an analysis here always follows everyone")
        addScreenshot(named: "processing-idle")
    }

    /// "Clip it" pushes Name Clips straight from the idle state with the result marked as
    /// skipped — the real `navigationDestination` binding flip, not just the view model's
    /// state — where the empty state offers "Analyze clips" and "Clip manually".
    func testProcessingClipItPushesTheEmptyClipList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingIdle"]
        app.launch()
        let clipIt = app.buttons["processing-clip-it"]
        XCTAssertTrue(clipIt.waitForExistence(timeout: 15))
        clipIt.tap()
        let notice = app.staticTexts["no-tricks-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "Clip it never pushed the clip list")
        XCTAssertEqual(notice.label, "No clips yet", "a skipped video read as one that found nothing")
        XCTAssertTrue(app.buttons["Analyze clips"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Clip manually"].exists)
        addScreenshot(named: "name-clips-empty")
    }

    /// The empty clip list's "Analyze clips" returns to Processing and runs the analysis there,
    /// under its progress, rather than leaving for Home.
    func testNameClipsAnalyzeReturnsToProcessingAndRuns() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingIdle"]
        app.launch()
        let clipIt = app.buttons["processing-clip-it"]
        XCTAssertTrue(clipIt.waitForExistence(timeout: 15))
        clipIt.tap()
        let analyze = app.buttons["Analyze clips"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 15))
        analyze.tap()
        let progress = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Analysis progress'"))
            .firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15), "the analysis never showed its progress")
        XCTAssertTrue(app.buttons["processing-cancel"].exists)
        XCTAssertFalse(app.buttons["processing-clip-it"].exists, "Clip it stayed up during the run")
        XCTAssertFalse(
            app.staticTexts[HarnessIdentifier.poppedToRoot].exists, "leaving the list for the run also left for Home")
    }

    /// A camera take that lands on Name Clips with nothing found has no Processing screen under
    /// it to analyze on, so its empty state offers "Clip manually" alone.
    func testCameraTakeEmptyStateOffersClipManuallyAlone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotNameClipsCameraEmpty"]
        app.launch()
        let notice = app.staticTexts["no-tricks-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertEqual(notice.label, "No tricks found")
        let clipManually = app.buttons["name-clips-clip-manually"]
        XCTAssertTrue(clipManually.waitForExistence(timeout: 5))
        XCTAssertEqual(clipManually.label, "Clip manually")
        XCTAssertFalse(app.buttons["Analyze clips"].exists, "a camera take offered an analysis it has no screen for")
    }

    /// A swipe on Processing browses to the neighboring video — the whole page follows the
    /// finger and the neighbor lands — rather than paging the app's Profile/Home container
    /// or doing nothing. Driven with real synthesized drags against the harness's page
    /// `TabView`, because that pager's UIKit recognizer is exactly what no gesture priority
    /// in SwiftUI can beat, and only a real touch exercises it. The harness's stand-in
    /// videos carry solid red/green/blue posters, so the screen's center color says which
    /// one is showing; the stand-in Profile page is gray, so a swipe that reached the pager
    /// reads as neither.
    func testProcessingSwipeBrowsesNeighborsInsteadOfPaging() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingBrowse"]
        app.launch()
        XCTAssertTrue(app.buttons["processing-clip-it"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitForCenterColor(.green), "did not start on the middle (green) stand-in video")

        // Left, from the middle of the screen: the next (blue) video.
        drag(app, fromX: 0.7, toX: 0.05, y: 0.5)
        XCTAssertTrue(waitForCenterColor(.blue), "left swipe did not land on the next video")
        XCTAssertTrue(
            waitUntilHittable(app.buttons["processing-clip-it"]), "the landed screen's controls never arrived")

        // Right, starting at the leading edge where the navigation stack's edge-pop would
        // otherwise claim it: back to green.
        drag(app, fromX: 0.01, toX: 0.7, y: 0.5)
        XCTAssertTrue(waitForCenterColor(.green), "right swipe from the leading edge did not land on the previous")

        // Right, from the top band under the status bar: the previous (red) video.
        drag(app, fromX: 0.5, toX: 0.98, y: 0.09)
        XCTAssertTrue(waitForCenterColor(.red), "right swipe from the top band did not land on the previous video")

        // Right again at the newest end of the grid: nothing that way, and in particular
        // not the Profile page.
        drag(app, fromX: 0.3, toX: 0.95, y: 0.5)
        sleep(1)
        XCTAssertTrue(waitForCenterColor(.red), "right swipe at the end of the grid left the video")
        XCTAssertTrue(waitUntilHittable(app.buttons["processing-clip-it"]), "the screen's controls did not settle")
        addScreenshot(named: "processing-browse")

        // Left, starting on "Clip it": a drag from a corner control swipes like any other. It
        // lifts well off the button, so it checks the browse only; the tap standing down is
        // `testProcessingCornerControlsStandDownWhileABrowseIsPending`.
        let clipIt = app.buttons["processing-clip-it"]
        clipIt.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)),
            withVelocity: XCUIGestureVelocity(900), thenHoldForDuration: 0.05)
        XCTAssertTrue(waitForCenterColor(.green), "a swipe starting on Clip it did not browse to the next video")
        XCTAssertTrue(waitUntilHittable(clipIt), "the landed screen's controls never arrived")
    }

    /// While a committed browse is still waiting on its neighbor, the corner controls' taps
    /// stand down: "Clip it" would open the clip list for the video sliding away, and the
    /// chevron would leave for Home. `-browseHeld` starts the neighbor's browse but never lands
    /// it, so the swipe stays in flight with the neighbor's poster on screen, and a tap that
    /// acted would push the black clip list or pop to the stand-in Home, which nothing replaces.
    func testProcessingCornerControlsStandDownWhileABrowseIsPending() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshotProcessingBrowse", "-browseHeld"]
        app.launch()
        let clipIt = app.buttons["processing-clip-it"]
        XCTAssertTrue(clipIt.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForCenterColor(.green), "did not start on the middle (green) stand-in video")

        drag(app, fromX: 0.7, toX: 0.05, y: 0.5)
        XCTAssertTrue(waitForCenterColor(.blue), "the left swipe did not carry the next video in")

        clipIt.tap()
        sleep(1)
        XCTAssertTrue(waitForCenterColor(.blue), "Clip it acted on the video the swipe was leaving")

        app.buttons["processing-back"].tap()
        sleep(1)
        XCTAssertTrue(waitForCenterColor(.blue), "the back chevron acted while the browse was pending")
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
        // Print base64 PNG to stdout so a local run can capture it (env vars
        // don't propagate to the test runner, and xcresult parsing is fragile).
        // The log line format is TURNIP_SCREENSHOT:<name>:<base64>.
        let b64 = screenshot.pngRepresentation.base64EncodedString()
        print("TURNIP_SCREENSHOT:\(name):\(b64)")
    }
}
