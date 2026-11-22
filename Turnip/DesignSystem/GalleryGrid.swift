import SwiftUI

/// The square-tile grid Home's gallery and a trick's clips on the Profile share: as many columns
/// as fit tiles of at least `minimumTileWidth`, three to six, `spacing` apart. Each screen reads its
/// own width and asks for its columns here, so a wider screen widens both grids the same way.
enum GalleryGrid {
    static let spacing: CGFloat = 2
    /// The narrowest a tile gets before the grid drops a column. A fourth column fits from
    /// 518 pt across, wider than any iPhone held upright (the widest is 440 pt), so every one of
    /// them keeps the three columns it has always shown.
    static let minimumTileWidth: CGFloat = 128
    static let columnRange = 3...6

    /// How many columns fit across `width`: as many tiles of at least `minimumTileWidth` as fit,
    /// never fewer than three — the grid every iPhone has always shown, even where the tiles come
    /// out a little narrower — and never more than six, so a wide screen shows bigger tiles rather
    /// than ever-smaller ones.
    static func columnCount(forWidth width: CGFloat) -> Int {
        let fitting = Int(((width + spacing) / (minimumTileWidth + spacing)).rounded(.down))
        return min(max(fitting, columnRange.lowerBound), columnRange.upperBound)
    }

    static func columns(forWidth width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount(forWidth: width))
    }
}
