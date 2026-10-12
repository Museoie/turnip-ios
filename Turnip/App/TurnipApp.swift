import SwiftUI

@main
struct TurnipApp: App {
    init() {
        // The sweep races in-flight resolutions: this session can export a fresh composition
        // while the detached sweep below is still snapshotting tmp/. The launch timestamp
        // captured here bounds what the sweep may delete, so only exports orphaned by
        // previous sessions are swept and anything written after launch is never touched.
        // See `PhotoVideoResolver.deleteOrphanedTemporaryExports`.
        let launchDate = Date()
        Task.detached(priority: .utility) {
            PhotoVideoResolver.deleteOrphanedTemporaryExports(olderThan: launchDate)
        }
        #if DEBUG
        if CommandLine.arguments.contains("-screenshotClipEditor")
            || CommandLine.arguments.contains("-screenshotClipListMedia")
            || CommandLine.arguments.contains("-screenshotProcessingPose") {
            // Start the harness's sample-movie encode before any view appears, on
            // a background queue, so the first render usually doesn't stall on it.
            // `-screenshotClipListMedia` and `-screenshotProcessingPose` share the
            // same generated movie.
            ScreenshotClipEditorHarness.warmUpSampleMovie()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if CommandLine.arguments.contains("-screenshotHome") {
                    ScreenshotHomeHarness()
                } else if CommandLine.arguments.contains("-screenshotGalleryFilter") {
                    ScreenshotGalleryFilterHarness()
                } else if CommandLine.arguments.contains("-screenshotClipListMedia") {
                    ScreenshotClipListMediaHarness()
                } else if CommandLine.arguments.contains("-screenshotClipList") {
                    ScreenshotClipListHarness()
                } else if CommandLine.arguments.contains("-screenshotClipEditor") {
                    ScreenshotClipEditorHarness()
                } else if CommandLine.arguments.contains("-screenshotProcessingBrowse") {
                    ScreenshotProcessingBrowseHarness()
                } else if CommandLine.arguments.contains("-screenshotProcessingIdle") {
                    ScreenshotProcessingIdleHarness()
                } else if CommandLine.arguments.contains("-screenshotProcessing") {
                    ScreenshotProcessingHarness()
                } else if CommandLine.arguments.contains("-screenshotProcessingPose") {
                    ScreenshotProcessingPoseHarness()
                } else if CommandLine.arguments.contains("-screenshotHomeExpansion") {
                    ScreenshotHomeExpansionHarness()
                } else if CommandLine.arguments.contains("-screenshotSettings") {
                    ScreenshotSettingsHarness()
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
            // Forced here, not just in `ContentView`, so the DEBUG-only screenshot
            // harnesses above — which never mount `ContentView` — render dark too.
            // The app is black-on-dark throughout; CI's PR screenshots are only
            // honest about that if the harnesses match what a user actually sees.
            .preferredColorScheme(.dark)
        }
    }
}
