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
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if CommandLine.arguments.contains("-screenshotExportConfirmationFinished") {
                    ScreenshotHarness(finishImmediately: true)
                } else if CommandLine.arguments.contains("-screenshotExportConfirmation") {
                    ScreenshotHarness(finishImmediately: false)
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
            // OTA model-update poll (issue #96): didBecomeActive fires on
            // launch and on every foreground transition. checkForUpdates
            // dispatches itself to a detached utility-QoS task, so the
            // manifest fetch, hashing, and atomic stage stay off the main
            // actor. Inert until TURNIP_MODEL_UPDATE_ENDPOINT is set — see
            // ModelUpdateLifecycle.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didBecomeActiveNotification)
            ) { _ in
                ModelUpdateLifecycle.checkForUpdates()
            }
        }
    }
}
