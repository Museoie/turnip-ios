import UIKit

/// Speaks one message through VoiceOver, regardless of what the user is focused on.
///
/// Injected as a closure at every call site so the decision to speak — the part that has
/// rules behind it — is assertable without a running screen reader.
typealias AccessibilityAnnouncing = @MainActor (String) -> Void

/// Hands `message` to VoiceOver, and does nothing when no screen reader is listening.
///
/// `UIAccessibility.post` rather than SwiftUI's `AccessibilityNotification.Announcement`:
/// that type is iOS 17+ and the deployment floor is 16.0 (`project.yml`).
@MainActor
func postAccessibilityAnnouncement(_ message: String) {
    UIAccessibility.post(notification: .announcement, argument: message)
}

/// `postAccessibilityAnnouncement`, held back until a screen change starting now has
/// settled: VoiceOver drops an announcement posted while the screen is changing.
@MainActor
func postAccessibilityAnnouncementAfterScreenChange(_ message: String) {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        postAccessibilityAnnouncement(message)
    }
}
