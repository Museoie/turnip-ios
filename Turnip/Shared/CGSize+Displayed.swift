import CoreGraphics

extension CGSize {
    /// The upright size of a frame of this size after `transform`: the bounding box
    /// of the frame's corners through the transform, so a 90°-rotated track reports
    /// portrait dimensions. `CGRect.applying` already maps the four corners and takes
    /// their bounding box; `standardized` keeps width and height non-negative.
    ///
    /// Single home for the geometric definition the clip editor, the clip list, the
    /// exporter, the pose diagnostic view, and the frame sampler all lay out against —
    /// one implementation instead of five.
    func displayed(through transform: CGAffineTransform) -> CGSize {
        CGRect(origin: .zero, size: self).applying(transform).standardized.size
    }
}
