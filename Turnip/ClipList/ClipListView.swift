import AVFoundation
import SwiftUI
import UIKit

/// The triage screen (`docs/UIUX.md` § "Clip List (triage)"): a grid of square tiles
/// — the original video first, then one per detected trick window, then a trailing
/// "+" tile that appends a new clip. Each tile autoplay-loops its window inline
/// (accessibility permitting) so the grid reads like a wall of tiny previews rather
/// than static frames, draws a read-only timeline over the bottom showing where its
/// window sits in the full source video (not adjustable here — that's what the
/// editor is for, and the original tile has none since its window is the whole
/// video), and carries the trash button. Tapping a derived clip's tile opens the
/// full `ClipEditorView` directly — "view large" and "edit" are the same entry
/// point, not a separate icon; the original tile isn't tappable, since editing the
/// source video isn't a thing this screen does.
///
/// "Save Clips" exports and saves every non-trashed derived clip to Photos, deletes the
/// original from Photos if its tile was trashed, and pops back to Home — there is no
/// separate export/confirmation screen.
///
/// An analysis that detected zero tricks still lands here — the original tile and the
/// "+" tile, same as any other triage — rather than on a dead-end screen of its own;
/// `showsNoTricksFound` then puts up a dismissible glass notice over the grid to say so.
///
/// The processing screen pushes this with the pipeline's output. The back chevron
/// pops to Home rather than to the processing screen, Photos-app style — centered
/// inline title on the same line as the chevron. This view deliberately declares no
/// `NavigationStack` of its own — it lives on the flow's shared stack.
struct ClipListView: View {
    @StateObject private var viewModel: ClipListViewModel
    @State private var expandTarget: ExpandTarget?
    /// The tile whose slot is emptied while its clip is expanded, Photos-style. Set by
    /// `ClipExpansionContainer` the instant its opening flight starts moving — not at
    /// presentation, since the container's card first waits for its video surface to be
    /// able to show the tile's frame, and until then the tile itself is what's on screen.
    /// Cleared when the cover is dismissed.
    @State private var hiddenItemID: UUID?
    /// Whether the "No tricks found" glass notice is up — seeded from `showsNoTricksFound`
    /// at init, then owned here so a tap or the notice's own timeout can dismiss it.
    @State private var isShowingNoTricksNotice: Bool
    let popToRoot: () -> Void

    /// How the grid reflows when a derived clip is removed: the tiles after it (and the "+"
    /// tile) slide to their new slots on this curve. Wrapped around the removal itself at
    /// both call sites — a tile's trash button and the editor's Delete — rather than attached
    /// to the grid with `.animation(_:value:)`, so an edit commit or the original tile's
    /// trash toggle, which change `items` without removing anything, stay unanimated.
    static let removalAnimation: Animation = .easeInOut(duration: removalDuration)
    /// How the removed tile itself leaves: a fade to the background on its own ease-out,
    /// carried by the transition so it isn't the ease-in-out the reflow around it plays.
    /// Insertion stays a cut — the "+" tile appends a clip with no animated transaction.
    static let removalTransition: AnyTransition = .asymmetric(
        insertion: .identity,
        removal: .opacity.animation(.easeOut(duration: removalDuration)))
    private static let removalDuration: TimeInterval = 0.15

    init(
        items: [ClipListItem],
        poseFrames: [PoseFrameResult] = [],
        asset: AVAsset,
        assetIdentifier: String,
        duration: TimeInterval,
        loader: ClipThumbnailLoader = ClipThumbnailLoader(),
        showsNoTricksFound: Bool = false,
        popToRoot: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: ClipListViewModel(
            items: items, poseFrames: poseFrames, asset: asset, assetIdentifier: assetIdentifier,
            duration: duration, loader: loader))
        _isShowingNoTricksNotice = State(initialValue: showsNoTricksFound)
        self.popToRoot = popToRoot
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .top),
                    GridItem(.flexible(), alignment: .top)
                ],
                spacing: 16
            ) {
                ForEach(viewModel.items) { item in
                    ClipCardView(
                        item: item,
                        viewModel: viewModel,
                        isSuspended: expandTarget != nil,
                        isHidden: hiddenItemID == item.id,
                        onOpen: item.isOriginal ? nil : { frame, thumbnail, loopTime in
                            presentExpandTarget(ExpandTarget(
                                id: item.id,
                                sourceFrame: frame,
                                sourceTime: loopTime ?? (item.window.startTime + item.window.endTime) / 2,
                                thumbnail: thumbnail,
                                // Snapshot now, rather than re-deriving from
                                // `viewModel.binding(for:)` inside `editor(for:)`:
                                // Delete removes the item from `viewModel.items`
                                // synchronously, before the container's own close
                                // animation finishes, and a binding lookup at that
                                // point would come back nil.
                                source: viewModel.editorSource(for: item)))
                        })
                    .transition(Self.removalTransition)
                }
                AddClipTile { Task { await viewModel.addClip() } }
            }
            .padding()
        }
        .disabled(viewModel.isSaving)
        .navigationTitle("Clips")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        // The grid runs edge-to-edge under the status bar/nav bar; without hiding the
        // bar's own background, its blur would opaque out the tiles underneath.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // The default back chevron would step back to the processing screen;
            // the flow's "back" is Home, so this screen draws its own chevron —
            // Photos-style, chevron only, no text label. The same 44 pt glass circle
            // the editor and Processing draw, so the chevron reads as one control
            // across the flow: on iOS 26 the bar would otherwise wrap the item in its
            // own wider pill, so that shared background is hidden under it.
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarLeading) { backButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigationBarLeading) { backButton }
            }
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryActionBar("Save Clips", isEnabled: !viewModel.isSaving) {
                Task {
                    if await viewModel.save() {
                        popToRoot()
                    }
                }
            }
        }
        .overlay {
            if viewModel.isSaving {
                savingOverlay
            }
        }
        .alert("Couldn't save clips", isPresented: saveFailurePresented) {
            Button("OK") {}
        } message: {
            Text(viewModel.saveFailureMessage ?? "")
        }
        .fullScreenCover(item: $expandTarget, onDismiss: { hiddenItemID = nil }, content: { target in
            editor(for: target)
        })
        .overlay(alignment: .top) {
            if isShowingNoTricksNotice {
                GlassNoticeView(message: "No tricks found", isPresented: $isShowingNoTricksNotice)
                    .padding(.top, 8)
                    .accessibilityIdentifier("no-tricks-notice")
            }
        }
    }

    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to Home", action: popToRoot)
            .disabled(viewModel.isSaving)
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            ProgressView {
                Text("Saving to Photos…")
            }
            .tint(.white)
            .foregroundStyle(.white)
        }
    }

    private var saveFailurePresented: Binding<Bool> {
        Binding(
            get: { viewModel.saveFailureMessage != nil },
            set: { if !$0 { viewModel.saveFailureMessage = nil } }
        )
    }

    /// Sets `expandTarget`, suppressing the system's own slide-up transition for the cover's
    /// appearance the same two-layer way `HomeView.presentSlot(_:)` does — see that method's
    /// own doc comment for the full story. `Transaction.disablesAnimations` alone was believed
    /// sufficient here (unlike Home's equivalent, which needed `UIView.setAnimationsEnabled`
    /// too), a conclusion `docs/EXPANSION_TRANSITIONS.md` already flagged as never properly
    /// isolated; a reported brief shrink-then-expand glitch right at tap time traces to
    /// exactly this same residual `present(animated:)` gap, so both suppressions apply here now
    /// too, with the same re-enable-on-the-next-run-loop-turn timing that was already proven
    /// sufficient for the open side (only the *close* side needed a longer hold).
    private func presentExpandTarget(_ target: ExpandTarget) {
        UIView.setAnimationsEnabled(false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expandTarget = target
        }
        DispatchQueue.main.async {
            UIView.setAnimationsEnabled(true)
        }
    }

    /// The tile tap's destination: the full `ClipEditorView` (crop + trim) — tapping
    /// goes directly to the editor rather than through an intermediate full-screen
    /// viewer, merging "view large" and "edit" into one entry point. `ClipExpansionContainer`
    /// flies the tile's own frame open into it, Photos-style, and closes itself via
    /// `@Environment(\.dismiss)` on its own reverse-flight schedule, which resets
    /// `expandTarget` to `nil` — each tile's `isSuspended` flag (derived from
    /// `expandTarget`) then lets its player resume.
    private func editor(for target: ExpandTarget) -> some View {
        let container = ClipExpansionContainer(
            sourceFrame: target.sourceFrame,
            sourceTime: target.sourceTime,
            thumbnail: target.thumbnail,
            source: target.source,
            onCommit: { result in viewModel.applyEditorResult(result, to: target.id) },
            onDelete: { withAnimation(Self.removalAnimation) { viewModel.delete(target.id) } },
            onFlightStarted: { hiddenItemID = target.id }
        )
        // Lets the grid show through the cover while the card/scrim animate —
        // `ClipExpansionContainer` draws its own opaque scrim at `progress`, so
        // without this the system's default opaque cover background would hide
        // the grid the interactive dismiss is supposed to reveal. iOS 16.4+ only;
        // earlier OSes keep the flight animation but lose the reveal-through-drag.
        return Group {
            if #available(iOS 16.4, *) {
                container.presentationBackground(.clear)
            } else {
                container
            }
        }
    }
}

/// The tapped tile's presentation target: `UUID` alone isn't `Identifiable`, and
/// `fullScreenCover(item:)` needs one to know which clip to open (and to dismiss when
/// it goes back to `nil`). Carries the tile's own frame and poster thumbnail at tap
/// time so `ClipExpansionContainer` can fly open from exactly there.
private struct ExpandTarget: Identifiable {
    let id: UUID
    let sourceFrame: CGRect
    /// The frame the tile was showing at the tap, in asset time — see
    /// `ClipExpansionContainer.sourceTime`.
    let sourceTime: TimeInterval
    let thumbnail: CGImage?
    /// Snapshotted at tap time rather than re-derived from `viewModel.binding(for:)`
    /// later: Delete removes the item from `viewModel.items` synchronously, before
    /// `ClipExpansionContainer`'s own close animation finishes, and a live lookup at
    /// that point would already be nil.
    let source: ClipEditorSource
}

/// The "+" tile: a grey square with a centered plus sign, appended after every clip
/// card. Tapping it appends a new full-frame clip at the start of the asset (`docs/UIUX.md`
/// § "Clip List (triage)"), which the user then trims like any other card.
private struct AddClipTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemFill))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add clip")
    }
}

/// One triage tile: a square clip surface (an autoplay-looping preview; its poster
/// thumbnail stands in only until the loop's first frame is up, so there's no blank flash
/// while the loop's player becomes ready and no second picture under the loop once it
/// plays) with the trash button at the top-trailing corner and, for a derived clip, a
/// read-only range timeline overlaid on the bottom edge — siblings drawn as overlays
/// on the tap-driven media layer rather than nested inside a shared `Button`, so each
/// keeps its own hit target instead of racing the tile's tap.
///
/// Drives its own `ClipCardPlayback` rather than sharing one across the grid: every
/// visible tile loops simultaneously, which a single shared player can't do. `LazyVGrid`
/// mounting/unmounting off-screen tiles bounds how many of these run concurrently to
/// what's on (or near) screen, via the `onAppear`/`onDisappear` pair below.
private struct ClipCardView: View {
    let item: ClipListItem
    @ObservedObject var viewModel: ClipListViewModel
    /// True while the full-screen editor is up, per `ClipListView.expandTarget`. The
    /// editor's `fullScreenCover` doesn't reliably fire `onDisappear` on the tiles
    /// behind it, so this is the signal that actually pauses them instead.
    let isSuspended: Bool
    /// True for exactly the tile whose clip is currently expanded — Photos empties
    /// a tile's slot while its photo is one-up. `ClipExpansionContainer`'s own
    /// flying card stands in at this tile's frame, so hiding it (rather than
    /// removing it) avoids any layout reflow in the grid underneath.
    let isHidden: Bool
    /// Opens the editor on this clip, passing the tile's own on-screen frame (global
    /// space), its already-decoded poster thumbnail, and the asset time its loop is
    /// paused on (`nil` without a loop) so the presenter can fly open from exactly here,
    /// on exactly this frame — `nil` for the original item, whose tile has no tap action.
    let onOpen: ((CGRect, CGImage?, TimeInterval?) -> Void)?

    @State private var thumbnail: CGImage?
    @State private var duration: TimeInterval?
    /// Whether the mounted loop's player layer has a frame to draw. The poster is drawn
    /// only until then: a trashed tile is translucent, and a poster left under a playing
    /// loop would show through it as a second, offset copy of the picture. Reset whenever
    /// the loop is rebuilt (an editor commit), since the new player starts frameless.
    @State private var isLoopReady = false
    @StateObject private var playback: ClipCardPlayback

    init(
        item: ClipListItem,
        viewModel: ClipListViewModel,
        isSuspended: Bool,
        isHidden: Bool,
        onOpen: ((CGRect, CGImage?, TimeInterval?) -> Void)?
    ) {
        self.item = item
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.isSuspended = isSuspended
        self.isHidden = isHidden
        self.onOpen = onOpen
        _playback = StateObject(
            wrappedValue: ClipCardPlayback(
                asset: viewModel.sourceAsset,
                loadComposition: { [viewModel] cropRect, cropAdjustment in
                    await viewModel.videoComposition(
                        cropRect: cropRect, cropAdjustment: cropAdjustment)
                },
                loadDuration: { [viewModel] in await viewModel.assetDuration() }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tile
            Text(item.isOriginal ? "Original video" : item.durationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isHidden ? 0 : 1)
        .task(id: item) {
            // Keyed by the item value, not just its id: `ForEach` keeps this card's own
            // identity stable across an editor commit, so an unkeyed `.task` would never
            // re-fire when window/cropRect/cropAdjustment change. The thumbnail decode and
            // the shared asset duration each dedupe/cache in the view model, so a re-fired
            // task joins work already done instead of repeating it. Also gives the preview
            // loop a second, differently-scheduled path to the current window alongside
            // `.onChange(of: item.window)` below.
            playback.start(geometry: currentPlaybackGeometry(), isSuspended: isSuspended)
            async let image = viewModel.thumbnail(for: item)
            async let assetDuration = viewModel.assetDuration()
            thumbnail = await image
            duration = await assetDuration
        }
        .onAppear {
            playback.start(geometry: currentPlaybackGeometry(), isSuspended: isSuspended)
        }
        .onDisappear { playback.teardown() }
        .onChange(of: isSuspended) { newValue in
            playback.setSuspended(newValue)
        }
        // Takes the new window from the change itself, and carries the framing from the
        // playback's own stored geometry, rather than reading `item` here: this closure can
        // run against a `self` captured before the commit that changed it.
        .onChange(of: item.window) { newWindow in
            playback.windowChanged(to: newWindow)
        }
    }

    /// The item's geometry as of the CURRENT render — safe to call only from a context
    /// guaranteed not to run against a stale `self` (`.task(id:)`'s own body, `.onAppear`),
    /// never from an `.onChange` action closure.
    private func currentPlaybackGeometry() -> ClipCardPlaybackGeometry {
        ClipCardPlaybackGeometry(
            window: item.window, cropRect: item.cropRect, cropAdjustment: item.cropAdjustment)
    }

    private var tile: some View {
        GeometryReader { proxy in
            mediaLayer
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { open(frame: proxy.frame(in: .global)) }
                // The UI-test screenshot harness waits on this label to prove the
                // thumbnail fallback actually engaged.
                .accessibilityLabel(tileAccessibilityLabel)
                .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { trashButton }
        .overlay(alignment: .bottom) { trimOverlay }
        .opacity(item.isTrashed ? 0.4 : 1)
        // After the opacity, so the notice reads at full strength over the dimmed tile.
        .overlay { deletionNotice }
    }

    /// What trashing the original tile means, said in words over it: the source video
    /// itself leaves Photos when "Save Clips" runs, which the dimmed tile and red trash
    /// button alone don't say. A derived clip's tile is gone the moment it's trashed, so
    /// only the original ever shows this.
    @ViewBuilder
    private var deletionNotice: some View {
        if item.isOriginal, item.isTrashed {
            Text("Will be deleted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.85), in: Capsule())
                .allowsHitTesting(false)
                .accessibilityIdentifier("original-deletion-notice")
        }
    }

    /// Pauses the loop first, then reads its position: the frame handed to the presenter
    /// has to be the one the tile keeps showing until it's hidden, and the suspension
    /// `isSuspended` applies on the next render would let the loop advance a frame past
    /// the time read here.
    private func open(frame: CGRect) {
        guard let onOpen else { return }
        playback.setSuspended(true)
        let loopTime = playback.loop.map { $0.player.currentTime() }
        onOpen(frame, thumbnail, loopTime.flatMap { $0.isNumeric ? $0.seconds : nil })
    }

    private var tileAccessibilityLabel: String {
        guard thumbnail != nil else { return "Thumbnail placeholder" }
        return item.isOriginal ? "Original video" : "Open clip"
    }

    @ViewBuilder
    private var mediaLayer: some View {
        ZStack {
            if isLoopReady {
                // The loop covers the whole tile from its first frame on; nothing is drawn
                // under it — see `isLoopReady`.
                Color.clear
            } else if let thumbnail {
                // The generator hands back the displayed (upright) frame, so `.up` is
                // exact — no UIKit bridge needed. The poster, until the loop's first frame:
                // the looper's item takes a moment to become ready, and without this the
                // tile would show black until it does. Also the tile's whole picture when
                // accessibility rules loops out (`ClipCardPlayback`).
                Image(decorative: thumbnail, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.quaternarySystemFill)
                    .overlay { ProgressView() }
            }
            if let loop = playback.loop {
                BareVideoPlayerView(
                    player: loop.player, videoGravity: .resizeAspectFill,
                    onReadyForDisplay: { isLoopReady = true })
            }
        }
        // A rebuilt loop is a new player with no frame yet, and a torn-down one (the tile
        // scrolled off) is no player at all: the poster comes back until the next player
        // has a frame. Watched on the stack, not inside the `if let` — a branch that is
        // removed and re-inserted never fires its own `onChange`, so a reset there would
        // miss exactly the teardown-and-rebuild a scroll-off-and-back is.
        .onChange(of: playback.loop.map { ObjectIdentifier($0.player) }) { _ in isLoopReady = false }
    }

    /// The diameter every top-corner icon circle renders at.
    private static let iconButtonDiameter: CGFloat = 28

    /// The per-tile trash button: a solid red circle while trashed, the same
    /// semi-transparent grey circle the other tile buttons use otherwise. For the
    /// original item, tapping it is the reversible toggle that tells "Save Clips" to
    /// delete the source video from Photos; for a derived clip, tapping it removes
    /// the tile from the grid, with no restore.
    private var trashButton: some View {
        Button(action: trash) {
            ZStack {
                Circle().fill(item.isTrashed ? Color.red : Color.black.opacity(0.4))
                Image(systemName: "trash")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.iconButtonDiameter, height: Self.iconButtonDiameter)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel(item.isTrashed ? "Restore clip" : "Trash clip")
    }

    /// A derived clip's removal reflows the grid on `ClipListView.removalAnimation`; the
    /// original tile's reversible toggle is a plain state flip, so it gets no animation.
    private func trash() {
        withAnimation(item.isOriginal ? nil : ClipListView.removalAnimation) {
            viewModel.trash(item)
        }
    }

    @ViewBuilder
    private var trimOverlay: some View {
        if let duration, !item.isOriginal {
            ClipRangeTimelineView(window: item.window, duration: duration)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.35))
        }
    }
}

#Preview {
    NavigationStack {
        ClipListView(
            items: [
                ClipListItem(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
                ),
                ClipListItem(
                    window: TrickWindow(startTime: 9, endTime: 11.5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
                    isTrashed: true
                )
            ],
            // AVAsset is abstract and throws at runtime; AVURLAsset is the concrete
            // subclass. The URL resolves to nothing — the preview shows the
            // placeholder tiles, which is the honest fallback.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "preview",
            duration: 15
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("No tricks found") {
    NavigationStack {
        ClipListView(
            items: [],
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "preview",
            duration: 15,
            showsNoTricksFound: true
        )
    }
    .preferredColorScheme(.dark)
}
