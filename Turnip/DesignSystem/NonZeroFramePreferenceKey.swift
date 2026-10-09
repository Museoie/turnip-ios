import SwiftUI

/// A view's on-screen frame reported outward, reducing to the latest non-zero report.
///
/// A plain `value = nextValue()` lets any sibling that never reports — it contributes the
/// `.zero` default — overwrite a real measurement when it reduces last, and the frame then
/// stays `.zero` with nothing failing. Every frame key in the app needs the same guard, so
/// each conforms to this rather than repeating it.
protocol NonZeroFramePreferenceKey: PreferenceKey where Value == CGRect {}

extension NonZeroFramePreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
