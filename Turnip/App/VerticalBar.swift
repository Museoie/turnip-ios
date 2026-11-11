import SwiftUI
import UIKit

/// The system's vertical bar on iPhone Duo: the column along one side of the screen that holds the
/// status bar and, in apps built from the system's own bars, their toolbar items and tab bar
/// (Apple's "Prepare your app for iPhone Duo" and "Raise the bar with iPhone Duo" tech talks). It
/// shows on the outer display, and on the inner display in landscape, and reaches an app built with
/// the iOS 27.1 SDK as a safe-area inset on that one side only — 84 pt in the iOS 27.1 simulator,
/// against none on the other side — where every earlier iPhone held upright, the only way Turnip
/// runs, has no side inset at all. A build with an older SDK runs beside the column instead and
/// never sees it, so nothing here changes anything there.
///
/// Turnip's tab bar and Home's filter and settings controls are its own views, not the system's
/// bars, and the system only moves the bars of its own navigation containers into the column. So
/// `RootTabView` lays them out there itself, stacked as the guidance stacks the column — the
/// status bar at the top, the page's own controls under it, the tab bar at the foot — and keeps the
/// pager to the safe area beside it.
struct VerticalBar: Equatable {
    let edge: HorizontalEdge
    let width: CGFloat

    /// The narrowest side inset read as the vertical bar. A side inset that only rounds a corner or
    /// keeps clear of a camera is a few points; the bar's is 84.
    static let minimumWidth: CGFloat = 44

    /// The least distance from the top of the column to the first control laid out in it. The
    /// status bar's location, time and connection glyphs end about 166 pt down the column on the
    /// outer display.
    static let statusBarFloor: CGFloat = 172

    init(edge: HorizontalEdge, width: CGFloat) {
        self.edge = edge
        self.width = width
    }

    /// The vertical bar the safe area reports, or nil without one: the side whose inset is at least
    /// `minimumWidth` wider than the other's. Insets that match on both sides are a margin, not a
    /// bar, and the two sides are read independently, never as one value doubled.
    init?(safeAreaInsets insets: EdgeInsets) {
        let difference = insets.trailing - insets.leading
        if difference >= Self.minimumWidth {
            self.init(edge: .trailing, width: insets.trailing)
        } else if -difference >= Self.minimumWidth {
            self.init(edge: .leading, width: insets.leading)
        } else {
            return nil
        }
    }

    /// How far down the column its controls start: under the status bar at the top of it, as the
    /// system lays its own bar items out. Read from the scene, since SwiftUI reports no status bar
    /// frame, and never above `statusBarFloor`, since what the scene reports for a status bar standing
    /// in the column isn't documented. `statusBarFloor` until a window exists.
    @MainActor static var controlsTop: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let statusBar = scene?.statusBarManager?.statusBarFrame, !statusBar.isEmpty else {
            return statusBarFloor
        }
        return max(statusBar.maxY, statusBarFloor)
    }
}

/// Whether the root pages' tab bar and Home's own controls sit in the vertical bar beside the
/// pager (`VerticalBar`) rather than on the page: a page reads it to leave out the controls the
/// column now holds, and the room it would keep clear for the floating tab bar.
private struct RootControlsInVerticalBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rootControlsInVerticalBar: Bool {
        get { self[RootControlsInVerticalBarKey.self] }
        set { self[RootControlsInVerticalBarKey.self] = newValue }
    }
}
