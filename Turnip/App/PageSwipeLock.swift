import SwiftUI
import UIKit

/// Switches the enclosing page-style `TabView`'s swipe off and on from inside one of its
/// pages.
///
/// SwiftUI gives a page `TabView` no way to refuse a swipe, and no gesture attached inside a
/// page can win one: the pages are cells of a paging `UICollectionView`, whose pan recognizer
/// claims any horizontal drag ahead of SwiftUI's own gesture system, whatever priority the
/// gesture declares. A screen pushed inside a page whose own horizontal swipe means
/// something else — Processing, where it browses videos — would otherwise page to Camera on
/// every right swipe and have its left swipes swallowed by the pager's end-of-content bounce.
/// Disabling scrolling on that collection view is the lever UIKit offers: its recognizer
/// stands down and the drag reaches the page's content. Paging driven by the `TabView`'s
/// `selection` in code is unaffected.
///
/// The collection view is found by walking up from this view to the nearest paging
/// `UIScrollView`, and re-found on every update since the cell hosting a page can be
/// recycled. If the hierarchy holds no such view — a SwiftUI that pages some other way —
/// this does nothing, and the `TabView` swipes exactly as it would without it.
struct PageSwipeLock: UIViewRepresentable {
    /// Whether the `TabView` may page on a swipe right now.
    let swipeEnabled: Bool

    func makeUIView(context: Context) -> LockView {
        let view = LockView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: LockView, context: Context) {
        uiView.apply(swipeEnabled: swipeEnabled)
    }

    static func dismantleUIView(_ uiView: LockView, coordinator: ()) {
        uiView.apply(swipeEnabled: true)
    }

    final class LockView: UIView {
        private var swipeEnabled = true
        /// The pager last written to, so a pager this view has moved out from under is
        /// handed back its swipe rather than left locked.
        private weak var pager: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply(swipeEnabled: swipeEnabled)
        }

        func apply(swipeEnabled: Bool) {
            self.swipeEnabled = swipeEnabled
            let current = pagingScrollView
            if let previous = pager, previous !== current {
                previous.isScrollEnabled = true
            }
            pager = current
            current?.isScrollEnabled = swipeEnabled
        }

        private var pagingScrollView: UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView, scrollView.isPagingEnabled {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }
    }
}
