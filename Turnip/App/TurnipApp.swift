import SwiftUI

@main
struct TurnipApp: App {
    init() {
        // Composition exports orphaned by a session that never cleaned up (crash, force-quit,
        // watchdog kill) would otherwise sit in tmp/ forever; one sweep at launch bounds the
        // accumulation. See `PhotoVideoResolver.deleteOrphanedTemporaryExports`.
        PhotoVideoResolver.deleteOrphanedTemporaryExports()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
