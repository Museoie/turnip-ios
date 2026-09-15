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
        if CommandLine.arguments.contains("-screenshotClipEditor") {
            // Start the harness's sample-movie encode before any view appears, on
            // a background queue, so the first render usually doesn't stall on it.
            ScreenshotClipEditorHarness.warmUpSampleMovie()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if CommandLine.arguments.contains("-screenshotExportConfirmationFinished") {
                    ScreenshotHarness(finishImmediately: true)
                } else if CommandLine.arguments.contains("-screenshotExportConfirmation") {
                    ScreenshotHarness(finishImmediately: false)
                } else if CommandLine.arguments.contains("-screenshotHome") {
                    ScreenshotHomeHarness()
                } else if CommandLine.arguments.contains("-screenshotClipList") {
                    ScreenshotClipListHarness()
                } else if CommandLine.arguments.contains("-screenshotClipEditor") {
                    ScreenshotClipEditorHarness()
                } else if CommandLine.arguments.contains("-screenshotProcessing") {
                    ScreenshotProcessingHarness()
                } else if CommandLine.arguments.contains("-screenshotPoseDiagnostic") {
                    ScreenshotPoseDiagnosticHarness()
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
        }
    }
}
