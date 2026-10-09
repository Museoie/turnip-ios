import CoreGraphics

/// The geometry behind Processing's swipe-to-browse: how far the page follows the finger
/// while a drag is in progress, and which neighbor — if any — letting go commits to. Kept
/// out of the view so the distances and the resistance at either end of the grid are
/// exercised without a running gesture.
enum BrowseSwipe {
    /// Which neighbor in Home's grid order a drag reaches. Dragging right moves the page
    /// right, which reads as uncovering the video before this one; dragging left, the one
    /// after.
    enum Direction {
        case previous
        case next
    }

    /// How far a drag must travel before letting go browses rather than springing back.
    static let commitDistance: CGFloat = 60

    /// How far a drag's projected end must reach for a quick flick that lifts short of
    /// `commitDistance` to browse anyway — the pager feel, where a fast short swipe turns
    /// the page and only a slow, short one is a change of mind.
    static let flickDistance: CGFloat = 200

    /// The fraction of the finger's travel the page follows when there is no neighbor that
    /// way — enough that the drag is visibly seen, short enough that it doesn't promise a
    /// video that isn't there.
    static let endOfGridResistance: CGFloat = 0.25

    /// The page's horizontal offset partway through a drag that has moved `translation`.
    static func pageOffset(translation: CGFloat, hasPrevious: Bool, hasNext: Bool) -> CGFloat {
        guard let direction = direction(of: translation),
              !isAvailable(direction, hasPrevious: hasPrevious, hasNext: hasNext)
        else { return translation }
        return translation * endOfGridResistance
    }

    /// The neighbor a drag of `translation` lands on once the finger lifts — nil when it fell
    /// short of `commitDistance` without a flick carrying `predictedTranslation` (where the
    /// drag would have ended had it kept its speed) past `flickDistance` the same way, or when
    /// there is no video that way.
    static func commit(
        translation: CGFloat,
        predictedTranslation: CGFloat? = nil,
        hasPrevious: Bool,
        hasNext: Bool
    ) -> Direction? {
        guard let direction = direction(of: translation),
              isAvailable(direction, hasPrevious: hasPrevious, hasNext: hasNext)
        else { return nil }
        if abs(translation) >= commitDistance {
            return direction
        }
        let predicted = predictedTranslation ?? translation
        guard self.direction(of: predicted) == direction, abs(predicted) >= flickDistance else {
            return nil
        }
        return direction
    }

    private static func direction(of translation: CGFloat) -> Direction? {
        if translation > 0 { return .previous }
        if translation < 0 { return .next }
        return nil
    }

    private static func isAvailable(
        _ direction: Direction, hasPrevious: Bool, hasNext: Bool
    ) -> Bool {
        switch direction {
        case .previous: return hasPrevious
        case .next: return hasNext
        }
    }
}
