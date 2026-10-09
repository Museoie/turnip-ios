import SwiftUI
import UIKit

/// Presents or dismisses a `fullScreenCover` with no system transition, for the expansion
/// containers that play their own flight instead.
///
/// `Transaction.disablesAnimations` alone leaves a residual slide: it suppresses SwiftUI's
/// animations but not the UIKit `present(animated:)` / `dismiss(animated:)` behind the cover.
/// `UIView.setAnimationsEnabled(false)` reaches that layer, and has to stay off until UIKit has
/// scheduled the transition: the next run-loop turn is enough for a present, but UIKit
/// schedules a dismiss's transition later, so a dismiss holds it off for half a second.
@MainActor
enum SystemTransition {
    /// How long a dismiss keeps UIKit animations off: shorter holds (down to one run-loop
    /// turn) still let the cover's dismiss slide play.
    static let dismissHold: TimeInterval = 0.5

    /// Runs `change` — the state write that presents a cover — with both layers' animations off.
    static func present(_ change: () -> Void) {
        UIView.setAnimationsEnabled(false)
        withAnimationsDisabled(change)
        DispatchQueue.main.async {
            UIView.setAnimationsEnabled(true)
        }
    }

    /// Runs `dismiss` with both layers' animations off, holding UIKit's off for `dismissHold`.
    static func dismiss(_ dismiss: () -> Void) {
        UIView.setAnimationsEnabled(false)
        withAnimationsDisabled(dismiss)
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissHold) {
            UIView.setAnimationsEnabled(true)
        }
    }
}

/// Runs `change` in a transaction that disables animations, so the views it drives cut
/// instantly even when it lands in the same update as an animated change.
func withAnimationsDisabled(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}
