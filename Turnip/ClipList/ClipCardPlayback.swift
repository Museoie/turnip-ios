import AVFoundation
import Combine
import Foundation
import UIKit

/// One tile's inline loop, behind a protocol so the lifecycle driving it is reachable
/// without a decoder: `AVPlayerLoop` is the real thing, tests inject a fake.
protocol ClipLooping: AnyObject {
    /// The player the tile's video layer renders.
    var player: AVQueuePlayer { get }
    func play()
    func pause()
    /// Releases the loop and the decode pipeline behind it. Not reusable afterwards —
    /// a later start builds a fresh loop.
    func stop()
}

/// Loops one window of an asset forever and muted, which needs an `AVQueuePlayer`
/// rather than a plain `AVPlayer`: `AVPlayerLooper` drives the repeat by keeping a
/// queue topped up with copies of its template item.
final class AVPlayerLoop: ClipLooping {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    /// `videoComposition` is attached to the template item *before* `AVPlayerLooper` is
    /// constructed from it: the looper reads the template's properties at construction, so
    /// patching it onto an already-looping item would not apply.
    init(asset: AVAsset, geometry: ClipCardPlaybackGeometry, videoComposition: AVVideoComposition?) {
        let templateItem = AVPlayerItem(sdrAsset: asset)
        templateItem.videoComposition = videoComposition
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        player = queuePlayer
        looper = AVPlayerLooper(
            player: queuePlayer,
            templateItem: templateItem,
            timeRange: CMTimeRange(
                start: CMTime(seconds: geometry.window.startTime, preferredTimescale: 600),
                end: CMTime(seconds: geometry.window.endTime, preferredTimescale: 600)))
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
    }
}

/// The playback lifecycle of one Clip List tile: builds the tile's loop when it should
/// be running, pauses it while the editor covers the grid, releases it when the tile
/// scrolls away, and rebuilds it over the new geometry when an editor commit changes the
/// window or the framing.
///
/// A reference type outside the view rather than `@State` on it, for two reasons. The
/// system accessibility reads, the composition load and the loop construction become
/// injectable, which is what makes the accessibility fallback and the rebuild assertable at
/// all. And the suspension flag and the geometry read live: SwiftUI can invoke an
/// `.onChange(of:)` action closure with a `self` captured from an earlier render than the
/// one that produced the new value, so the same state read off the view is stale from
/// inside that closure — observed as every tile bailing out of resume with suspension still
/// set right after the editor reported it clear, and as a resume after an editor commit
/// rebuilding over the pre-edit range.
@MainActor
final class ClipCardPlayback: ObservableObject {
    /// Loads the `videoComposition` a loop over this framing has to render through.
    typealias LoadComposition = @MainActor (
        _ cropRect: NormalizedRect, _ cropAdjustment: CropAdjustment
    ) async -> AVVideoComposition?
    /// Loads the source asset's real duration, for clamping a window before it reaches the
    /// looper. `nil` when it can't be read — the window then builds unclamped.
    typealias LoadDuration = @MainActor () async -> TimeInterval?
    /// Builds a loop showing `geometry` of `asset` through `videoComposition`.
    typealias MakeLoop = @MainActor (
        _ asset: AVAsset, _ geometry: ClipCardPlaybackGeometry,
        _ videoComposition: AVVideoComposition?
    ) -> any ClipLooping

    /// The mounted loop, or `nil` when the tile has none — it then shows only its
    /// static poster thumbnail.
    @Published private(set) var loop: (any ClipLooping)?
    /// The build currently in flight, or `nil` when none is. A caller arriving mid-build
    /// never needs it — it either joins the slot or replaces it — but observing the built
    /// loop does, since the composition load defers it past the call that asked for it.
    private(set) var buildTask: Task<Void, Never>?

    private let asset: AVAsset
    private let mayAutoplayLoops: @MainActor () -> Bool
    private let loadComposition: LoadComposition
    private let loadDuration: LoadDuration
    private let makeLoop: MakeLoop
    private var isSuspended = false
    private var geometry: ClipCardPlaybackGeometry?
    /// The geometry `loop` is actually built to show, or `nil` while there is no loop.
    private var loopGeometry: ClipCardPlaybackGeometry?
    /// The geometry a build is in flight for, so a second call for the SAME target that
    /// lands before the first one's loop exists (`.task(id:)` and `.onAppear` both firing
    /// on first appearance) joins it instead of racing a duplicate build.
    private var buildingGeometry: ClipCardPlaybackGeometry?
    /// Identifies which attempt currently owns `buildingGeometry`'s slot. That value alone
    /// can't tell two attempts for the same target apart — equality would let a cancelled
    /// attempt that unwinds after a later one re-claimed the identical target (scroll off
    /// mid-load, then back on) clear the live attempt's claim instead of its own.
    private var buildToken: UUID?

    init(
        asset: AVAsset,
        mayAutoplayLoops: @escaping @MainActor () -> Bool = {
            clipCardMayAutoplayLoops(
                isVideoAutoplayEnabled: UIAccessibility.isVideoAutoplayEnabled,
                isReduceMotionEnabled: UIAccessibility.isReduceMotionEnabled)
        },
        loadComposition: @escaping LoadComposition,
        loadDuration: @escaping LoadDuration = { nil },
        makeLoop: @escaping MakeLoop = {
            AVPlayerLoop(asset: $0, geometry: $1, videoComposition: $2)
        }
    ) {
        self.asset = asset
        self.mayAutoplayLoops = mayAutoplayLoops
        self.loadComposition = loadComposition
        self.loadDuration = loadDuration
        self.makeLoop = makeLoop
    }

    /// Adopts the tile's current geometry and suspension state, then starts its loop. Safe
    /// to call repeatedly — an already-built loop matching the target is just resumed.
    func start(geometry: ClipCardPlaybackGeometry, isSuspended: Bool) {
        self.geometry = geometry
        self.isSuspended = isSuspended
        resume()
    }

    /// Releases the tile's decoder entirely rather than just pausing, so a tile scrolled
    /// far off-screen doesn't keep a decode pipeline open behind ones that are visible.
    /// Also cancels a build still in flight, so a tile that goes away mid-load never
    /// assigns a loop after the fact.
    func teardown() {
        buildTask?.cancel()
        buildTask = nil
        buildingGeometry = nil
        buildToken = nil
        loop?.stop()
        loop = nil
        loopGeometry = nil
    }

    /// Pauses while the editor covers the grid, and resumes when it closes. A pause keeps
    /// the loop mounted: the tile is still on screen and comes straight back.
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            loop?.pause()
        } else {
            resume()
        }
    }

    /// Rebuilds the loop over `window`. The grid keys its tiles by clip id, so an editor
    /// commit reuses this same tile — and, without the rebuild, its loop would keep playing
    /// the pre-edit range forever. Tears the old loop down eagerly rather than at the next
    /// resume, which releases the decoder for a range nothing will play again straight away.
    ///
    /// Carries the framing from the geometry already stored rather than taking it from the
    /// caller: the call site is an `.onChange` action closure, whose `self` can predate the
    /// commit that changed the window. Nothing is stored before the first `start`, and
    /// there is no loop to rebuild then either — that path arrives with the whole geometry.
    func windowChanged(to window: TrickWindow) {
        guard let current = geometry else { return }
        geometry = ClipCardPlaybackGeometry(
            window: window, cropRect: current.cropRect, cropAdjustment: current.cropAdjustment)
        teardown()
        resume()
    }

    /// The gates on playback: either accessibility setting set against looping rules out
    /// auto-playing loops entirely (`docs/ACCESSIBILITY.md`'s Clip List checklist — the
    /// tile shows its static poster instead), and a covered grid shouldn't be decoding
    /// behind the editor.
    ///
    /// Rebuilds a loop whose geometry no longer matches rather than assuming the caller
    /// that moved it also tore the loop down, so a geometry that arrives by any other path
    /// still can't leave the pre-edit range or framing looping indefinitely.
    ///
    /// The composition load re-checks suspension before assigning, so the editor opening
    /// mid-load can't leave a tile playing behind the cover — `setSuspended` only pauses an
    /// already-built loop.
    private func resume() {
        guard let target = geometry, mayAutoplayLoops(), !isSuspended else { return }
        if clipCardPlaybackNeedsRebuild(builtFor: loopGeometry, target: target) {
            teardown()
        }
        if let loop {
            loop.play()
            return
        }
        guard buildingGeometry != target else { return }
        // A different target replaces whatever was building — without this, the loser of
        // the race could still finish, get recorded into `loopGeometry`, and mask the
        // rebuild the winner's target needs.
        buildTask?.cancel()
        buildingGeometry = target
        let token = UUID()
        buildToken = token
        buildTask = Task { @MainActor [self] in
            async let compositionLoad = loadComposition(target.cropRect, target.cropAdjustment)
            async let durationLoad = loadDuration()
            let composition = await compositionLoad
            let duration = await durationLoad
            // Both loads are awaited before this check, not between them: a suspension
            // point after the guard would let a teardown/suspend that lands during the
            // second await slip past it, assigning a loop behind the editor's cover.
            guard !Task.isCancelled, !isSuspended else {
                releaseBuildSlot(token)
                return
            }
            let clamped = Self.clampedForLoop(target, to: duration)
            let built = makeLoop(asset, clamped, composition)
            loop = built
            loopGeometry = target
            releaseBuildSlot(token)
            built.play()
        }
    }

    /// Clamps `target`'s window into `[0, duration]` right before it reaches the looper.
    /// The detector's trailing buffer can leave a trick window's `endTime` past the asset's
    /// real duration (`TrickWindowDetector`'s own doc comment), most often on the LAST
    /// detected trick, whose landing tends to sit closest to when recording stopped. An
    /// `AVPlayerLooper` built from a `CMTimeRange` past the asset's duration never surfaces
    /// an error — it just never queues a playable item, so the tile is stuck showing its
    /// poster forever. `loopGeometry` still records the unclamped `target`: the rebuild
    /// check above compares against what the item actually carries, not what got built.
    /// Reuses `ClipEditorViewModel.clamped(window:to:)` rather than re-deriving the same
    /// bound a third time — the export path clamps this exact overshoot too
    /// (`ClipExporter.trimmedRange`).
    private static func clampedForLoop(
        _ target: ClipCardPlaybackGeometry, to duration: TimeInterval?
    ) -> ClipCardPlaybackGeometry {
        guard let duration else { return target }
        let clampedWindow = ClipEditorViewModel.clamped(window: target.window, to: duration)
        guard clampedWindow != target.window else { return target }
        return ClipCardPlaybackGeometry(
            window: clampedWindow, cropRect: target.cropRect, cropAdjustment: target.cropAdjustment)
    }

    /// Clears the in-flight slot only if `token` still owns it: a later attempt for the
    /// identical target may already have re-claimed it.
    private func releaseBuildSlot(_ token: UUID) {
        guard buildToken == token else { return }
        buildingGeometry = nil
        buildToken = nil
        buildTask = nil
    }
}

/// Everything a tile's live loop needs to play the right range with the right framing: a
/// window change alone needs a rebuild (a different `AVPlayerLooper` time range), and so
/// does a crop-rect or crop-adjustment change alone (a different `videoComposition`) —
/// trimming never touches `cropAdjustment` and an editor commit can change any subset of
/// the three.
struct ClipCardPlaybackGeometry: Equatable {
    let window: TrickWindow
    let cropRect: NormalizedRect
    let cropAdjustment: CropAdjustment
}

/// Whether a tile may auto-play its loop at all, from the two system settings the Clip
/// List checklist names. They are independent switches — Reduce Motion covers motion in
/// general, Auto-Play Video Previews only video previews — so either one set against
/// looping is enough to rule it out.
func clipCardMayAutoplayLoops(isVideoAutoplayEnabled: Bool, isReduceMotionEnabled: Bool) -> Bool {
    isVideoAutoplayEnabled && !isReduceMotionEnabled
}

/// Whether a mounted loop has to be replaced to show `target`: `builtFor` is `nil` when
/// there is no loop yet, which is nothing to rebuild. A plain value comparison, so the
/// rule holds where a loop can't be constructed at all.
func clipCardPlaybackNeedsRebuild(
    builtFor: ClipCardPlaybackGeometry?, target: ClipCardPlaybackGeometry
) -> Bool {
    guard let builtFor else { return false }
    return builtFor != target
}
