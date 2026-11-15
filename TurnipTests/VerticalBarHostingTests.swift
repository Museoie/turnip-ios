import SwiftUI
import UIKit
import XCTest
@testable import Turnip

/// Whether a screen is handed iPhone Duo's vertical bar (`\.verticalBar`) where it's presented,
/// hosted in a real window whose safe area carries the bar's inset on one side, the way the
/// iOS 27.1 SDK reports it. `RootNavigationTests` covers reading a bar from a set of insets; these
/// cover where in a view tree there are insets to read.
@MainActor
final class VerticalBarHostingTests: XCTestCase {
    /// The bar's inset, added to the simulator's own: an iPhone held upright, the only way Turnip
    /// runs, has none at the sides.
    private static let barInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84)

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// Processing and Name Clips, Home's destinations, lay their top controls down the bar from
    /// inside a container whose frame reaches past the safe area.
    func testHomeExpansionHandsItsDestinationTheBar() throws {
        let bar = try barRead(withExtraInset: Self.barInset) { probe in
            HomeExpansionContainer(
                sourceFrame: { nil }, thumbnail: nil, initialAspectRatio: nil, content: { _ in probe })
        }
        XCTAssertEqual(bar, VerticalBar(edge: .trailing, width: 84))
    }

    func testHomeExpansionHandsItsDestinationNoBarWithoutOne() throws {
        let bar = try barRead(withExtraInset: .zero) { probe in
            HomeExpansionContainer(
                sourceFrame: { nil }, thumbnail: nil, initialAspectRatio: nil, content: { _ in probe })
        }
        XCTAssertNil(bar)
    }

    /// The editor's container, which has no probe to host, reads the bar the same way: a view that
    /// ignores the safe area, as both containers' frames do, is handed the bar measured around it.
    func testAViewReachingPastTheSafeAreaIsHandedTheBarMeasuredAroundIt() throws {
        let trailing = try barRead(withExtraInset: Self.barInset) { probe in
            GeometryReader { _ in probe }
                .ignoresSafeArea()
                .measuresVerticalBar()
        }
        XCTAssertEqual(trailing, VerticalBar(edge: .trailing, width: 84))

        let leading = try barRead(withExtraInset: UIEdgeInsets(top: 0, left: 84, bottom: 0, right: 0)) { probe in
            GeometryReader { _ in probe }
                .ignoresSafeArea()
                .measuresVerticalBar()
        }
        XCTAssertEqual(leading, VerticalBar(edge: .leading, width: 84))
    }

    // MARK: - Hosting

    /// Hosts the view `root` builds around a probe in a window over the whole screen, its safe area
    /// widened by `extraInset`, and returns the bar the probe last read from its environment. Takes
    /// down the window an earlier call put up.
    private func barRead<Root: View>(
        withExtraInset extraInset: UIEdgeInsets, _ root: (VerticalBarProbe) -> Root
    ) throws -> VerticalBar? {
        window?.isHidden = true
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let reading = VerticalBarProbe.Reading()
        let appeared = expectation(description: "the probe appeared")
        appeared.assertForOverFulfill = false
        reading.onAppear = { appeared.fulfill() }

        let host = UIHostingController(rootView: root(VerticalBarProbe(reading: reading)))
        host.additionalSafeAreaInsets = extraInset
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.isHidden = false
        self.window = window

        wait(for: [appeared], timeout: 5)
        // A few more passes, for a safe area that settles after the first layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return reading.bar
    }
}

/// Reads `\.verticalBar` where a screen would, and keeps the last value it read.
private struct VerticalBarProbe: View {
    final class Reading {
        var bar: VerticalBar?
        var onAppear: (() -> Void)?
    }

    let reading: Reading
    @Environment(\.verticalBar) private var bar

    var body: some View {
        Color.clear
            .onAppear {
                reading.bar = bar
                reading.onAppear?()
            }
            .onChange(of: bar) { reading.bar = $0 }
    }
}
