import CoreGraphics
import UIKit

/// Loads a video's poster frame, aspect-fit into a size in pixels — nil when the library has
/// none to give. What Processing draws for a video before its player has a frame to show.
typealias PosterLoader = @MainActor (CGSize) async -> UIImage?

/// A video one swipe away from the one Processing is showing: what it looks like while it
/// slides in under the finger, and how to land on it once the swipe commits. Processing
/// never sees the library's own asset type; whoever pushes it supplies both halves.
struct BrowseNeighbor {
    /// The neighbor's poster frame, drawn on the page that slides in alongside the one leaving.
    let poster: PosterLoader
    /// Resolves the neighbor and replaces this screen with it. Returns `false` when nothing
    /// started — another resolution already in flight, or the neighbor gone from the library
    /// since the swipe began — so the page it was carrying off screen can be brought back.
    let browse: @MainActor () -> Bool
}
