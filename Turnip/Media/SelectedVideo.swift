import AVFoundation
import Foundation

/// The hand-off from Home to whatever consumes the picked video — the pose diagnostic today, the
/// Processing screen once it exists.
///
/// Carries the resolved `AVURLAsset` rather than a bare file URL. For ordinary Photos videos the
/// asset points into the Photos container, and it is the object PhotoKit handed back that carries
/// read access to that file; a fresh `AVURLAsset(url:)` on the same path is not guaranteed to open.
/// PhotoKit still stays out of the pipeline — consumers see AVFoundation, not `PHAsset`.
///
/// `Hashable` so it can be a `NavigationStack` path element. `Sendable` because `AVURLAsset` is
/// (`NS_SWIFT_SENDABLE`), so the value can cross into the off-main pipeline.
struct SelectedVideo: Hashable, Sendable {
    /// `PHAsset.localIdentifier` of the source, kept so later screens can re-fetch metadata or
    /// write results back next to the original.
    let assetIdentifier: String
    /// Readable asset. For ordinary Photos videos this is what PhotoKit returned; for compositions
    /// (slow-motion, edited) it wraps a temp-file export — see `PhotoVideoResolver`.
    let asset: AVURLAsset
    let duration: TimeInterval
}
