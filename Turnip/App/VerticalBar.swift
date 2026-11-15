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

    /// The deepest a reported status bar may reach, as a share of the window's height, and still be
    /// read as the top of the column rather than the whole of it.
    static let statusBarMaximumShare: CGFloat = 1.0 / 3.0

    /// How far down the column its controls start: under the status bar at the top of it, as the
    /// system lays its own bar items out. Read from the scene, since SwiftUI reports no status bar
    /// frame. `statusBarFloor` until a window exists.
    @MainActor static var controlsTop: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        return controlsTop(
            statusBar: scene?.statusBarManager?.statusBarFrame, windowHeight: window?.bounds.height ?? 0)
    }

    /// Where the column's controls start, given the status bar frame the scene reports and the
    /// window's height. What the scene reports for a status bar standing in the column isn't
    /// documented, so the frame is trusted only where it reads as the top of the column: it can push
    /// the controls below `statusBarFloor`, and never further than `statusBarMaximumShare` of the
    /// window down. A frame reaching deeper — one spanning the whole column — would put them off
    /// the bottom of the screen, so it's ignored and the floor stands.
    static func controlsTop(statusBar: CGRect?, windowHeight: CGFloat) -> CGFloat {
        guard let statusBar, !statusBar.isEmpty,
              statusBar.maxY <= windowHeight * statusBarMaximumShare
        else { return statusBarFloor }
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

/// The vertical bar a screen past the root lays its top controls down, or nil anywhere else
/// (`VerticalBar`). Set where the bar is measured: by `RootTabView` for the pages and the camera,
/// and by the expansion containers for the screens they present, which cover the whole window.
private struct VerticalBarKey: EnvironmentKey {
    static var defaultValue: VerticalBar? { nil }
}

/// Where a screen pushed from the Profile hands its top controls on iPhone Duo
/// (`VerticalBarSlot`); nil anywhere else.
private struct VerticalBarSlotKey: EnvironmentKey {
    static var defaultValue: VerticalBarSlot? { nil }
}

extension EnvironmentValues {
    var verticalBar: VerticalBar? {
        get { self[VerticalBarKey.self] }
        set { self[VerticalBarKey.self] = newValue }
    }

    var verticalBarSlot: VerticalBarSlot? {
        get { self[VerticalBarSlotKey.self] }
        set { self[VerticalBarSlotKey.self] = newValue }
    }
}

/// A screen's top controls laid down iPhone Duo's vertical bar instead (`VerticalBar`): stacked
/// from under the status bar, the way `RootTabView` stacks the root pages' controls there and the
/// system stacks its own bar items. Fills its container and reaches past the safe area into the
/// bar's side, so it goes over a screen whose own frame spans the window; only the controls take
/// touches.
struct VerticalBarColumn<Content: View>: View {
    let bar: VerticalBar
    @ViewBuilder let content: () -> Content

    var body: some View {
        let side: Edge.Set = bar.edge == .leading ? .leading : .trailing
        VStack(spacing: 12) {
            content()
        }
        .frame(width: bar.width)
        .padding(.top, VerticalBar.controlsTop)
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: bar.edge == .leading ? .topLeading : .topTrailing)
        .ignoresSafeArea(.container, edges: side.union(.top))
    }
}

/// Where a screen pushed from the Profile hands its top controls on iPhone Duo, for `RootTabView`
/// to lay down the vertical bar. The Profile's pages keep to the safe area beside the bar, so a
/// screen pushed there can't reach the column itself; the root draws it for whichever screen
/// appeared last, and the screen hands its controls over again whenever they change.
@MainActor
final class VerticalBarSlot: ObservableObject {
    @Published private(set) var controls: AnyView?
    private var owner: UUID?

    /// `owner`'s controls take the column: the screen has just appeared.
    func show(_ controls: AnyView, for owner: UUID) {
        self.owner = owner
        self.controls = controls
    }

    /// `owner`'s controls changed: redrawn only while they hold the column, so a screen still
    /// under a pushed one can't take it back.
    func update(_ controls: AnyView, for owner: UUID) {
        guard self.owner == owner else { return }
        self.controls = controls
    }

    /// `owner` disappeared. A screen that appeared meanwhile keeps the column: on a push or a pop
    /// the system can tell the arriving screen before the leaving one.
    func clear(for owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        controls = nil
    }
}

extension View {
    /// On iPhone Duo (`bar` set), lays a screen's top controls down the vertical bar over the
    /// screen (`VerticalBarColumn`), for a screen whose frame spans the window: the camera, and the
    /// screens the expansion containers present. Nothing anywhere else, where the screen keeps them
    /// along its top edge itself.
    func verticalBarColumn<Controls: View>(
        _ bar: VerticalBar?, @ViewBuilder controls: () -> Controls
    ) -> some View {
        let built = controls()
        return overlay {
            if let bar {
                VerticalBarColumn(bar: bar) { built }
            }
        }
    }

    /// On iPhone Duo, hands a screen the Profile pushed's top controls to `RootTabView` to lay down
    /// the vertical bar (`VerticalBarSlot`, through `\.verticalBarSlot`); nothing anywhere else.
    /// The controls are handed over as built, so `refreshingOn` is everything they read: a change
    /// hands them over again.
    func verticalBarSlotControls<Key: Equatable, Controls: View>(
        refreshingOn key: Key, @ViewBuilder _ controls: () -> Controls
    ) -> some View {
        modifier(VerticalBarSlotControls(key: key, controls: controls()))
    }

    /// `verticalBarSlotControls(refreshingOn:_:)` for controls that read nothing that changes.
    func verticalBarSlotControls<Controls: View>(@ViewBuilder _ controls: () -> Controls) -> some View {
        verticalBarSlotControls(refreshingOn: true, controls)
    }
}

private struct VerticalBarSlotControls<Key: Equatable, Controls: View>: ViewModifier {
    let key: Key
    let controls: Controls
    @Environment(\.verticalBarSlot) private var slot
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { slot?.show(AnyView(controls), for: owner) }
            .onChange(of: key) { _ in slot?.update(AnyView(controls), for: owner) }
            // The bar arriving while the screen is up: no appearance to hand the controls over on.
            .onChange(of: slot.map { ObjectIdentifier($0) }) { _ in
                slot?.show(AnyView(controls), for: owner)
            }
            .onDisappear { slot?.clear(for: owner) }
    }
}
