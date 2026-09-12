import SwiftUI

@main
struct TurnipApp: App {
    init() {
        // Composition exports orphaned by a session that never cleaned up (crash, force-quit,
        // watchdog kill) would otherwise sit in tmp/ forever; one sweep at launch bounds the
        // accumulation. Detached at utility priority: nothing downstream depends on it having
        // finished, so it stays off the main-thread launch path (watchdog budget).
        // See `PhotoVideoResolver.deleteOrphanedTemporaryExports`.
        Task.detached(priority: .utility) {
            PhotoVideoResolver.deleteOrphanedTemporaryExports()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
