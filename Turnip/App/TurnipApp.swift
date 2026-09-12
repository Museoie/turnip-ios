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
            ContentView()
        }
    }
}
