import SwiftUI
import UIKit

/// The system inline navigation bar's geometry, for the screens that draw their own top
/// controls instead of showing a bar (Processing, Camera, the clip editor, Home's pre-26
/// overlay). Every screen's header has to read as the same band — the editor flies open
/// from the clip list's titled bar and its chevron and title cross-fade over the list's, so
/// a row that sits lower or further in than the bar's items visibly jumps at the cut.
///
/// Measured against the real bar on an iPhone 15 (393 pt wide), since no public constant
/// exposes any of it: the bar's items are centered in a 44 pt row at the top of its band, with
/// the band 54 pt tall on iOS 26 (`HomeNavigationBar` relies on the same number to reclaim
/// that space) and 44 pt before; the leading item's glyph sits 42 pt in from the screen's
/// edge on iOS 26 (a 48 pt glass pill inset 20) and 38 pt before (a bare glyph inset 16).
enum ScreenHeaderMetrics {
    /// The height of the bar's whole band below the status bar.
    static var barHeight: CGFloat {
        if #available(iOS 26.0, *) { return 54 }
        return 44
    }

    /// The row the bar's items are centered in, at the top of the band.
    static let itemRowHeight: CGFloat = 44

    /// The inset from the screen's side edges that puts a 44 pt control's glyph where the
    /// bar's own leading glyph sits.
    static var horizontalInset: CGFloat {
        if #available(iOS 26.0, *) { return 20 }
        return 16
    }

    /// How far above the top safe-area inset the bar's band begins. Before iOS 26 the bar
    /// hangs from the status bar's bottom edge, which on Dynamic Island devices sits above
    /// the safe-area inset (a 54 pt status bar under a 59 pt inset), so a row laid out from
    /// the inset would land 5 pt below the bar's items. On iOS 26 the bar starts at the
    /// inset itself (measured: its frame begins at 59 while the status bar still reports
    /// 54), so no correction applies. Read from the scene, since SwiftUI exposes neither
    /// number; `0` until a window exists.
    static var topOverhang: CGFloat {
        if #available(iOS 26.0, *) { return 0 }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
              let statusBar = scene.statusBarManager
        else { return 0 }
        return max(window.safeAreaInsets.top - statusBar.statusBarFrame.height, 0)
    }
}

/// A bar-less screen's own header row, laid out exactly where the system inline bar
/// would lay its items: `content` fills a row of `ScreenHeaderMetrics.itemRowHeight`
/// inset by `horizontalInset`, and the view as a whole occupies the bar's full band,
/// so content stacked below it starts where it would under a real bar.
struct ScreenHeaderBand<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .screenHeaderItemPlacement()
            .padding(.bottom, ScreenHeaderMetrics.barHeight - ScreenHeaderMetrics.itemRowHeight)
    }
}

extension View {
    /// Places a bar-less screen's own corner control(s) where the system inline bar's items
    /// sit — for a control overlaid at a top corner of the screen rather than stacked as a
    /// row (`ScreenHeaderBand` is the full-width row). Applied to a view aligned to the top
    /// of the safe area. `hangsFromStatusBar` is the bar's own pre-26 placement
    /// (`ScreenHeaderMetrics.topOverhang`); `false` keeps the row at the safe-area top
    /// instead, for controls that share a row with content laid out from there rather
    /// than with a bar — Home's pre-26 overlay sits beside its wordmark header.
    func screenHeaderItemPlacement(hangsFromStatusBar: Bool = true) -> some View {
        frame(height: ScreenHeaderMetrics.itemRowHeight)
            .padding(.horizontal, ScreenHeaderMetrics.horizontalInset)
            .padding(.top, hangsFromStatusBar ? -ScreenHeaderMetrics.topOverhang : 0)
    }
}
