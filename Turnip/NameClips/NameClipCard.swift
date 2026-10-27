import AVFoundation
import SwiftUI

/// The clip a Name Clips page is about, at its fixed size: its window looping with the framing
/// export uses through `ClipCardPlayback`, over its poster until the loop has a frame. A card
/// beside the current page builds its loop paused on the first frame, so it slides in showing the
/// video it is about to play rather than a poster that cuts to it.
///
/// The card also carries the triage controls: the trash button, the saved-to-Photos badge, and
/// the read-only timeline of where the window sits in the video. A tap opens the editor, flying
/// the card open from where it sits.
///
/// The card's size comes from its caller and never from its content: a poster drawn
/// `scaledToFill` overflows whatever proposes its size, so the frame is fixed first and the
/// picture is clipped to it.
struct NameClipCard: View {
    let item: ClipListItem
    let side: CGFloat
    @ObservedObject var viewModel: ClipListViewModel
    /// Whether the loop may play: the page is the current one, and nothing covers it. A card that
    /// isn't playing keeps its loop, paused.
    let isPlaying: Bool
    /// True for the card whose clip is open in the editor; the flying card stands in for it.
    let isHidden: Bool
    /// Opens the editor from the card's on-screen frame (global space), on the poster and the
    /// asset time the loop was showing (`nil` without a loop).
    let onOpen: (CGRect, CGImage?, TimeInterval?) -> Void
    let onTrash: () -> Void

    @StateObject private var playback: ClipCardPlayback
    @State private var thumbnail: CGImage?
    @State private var duration: TimeInterval?
    /// Whether the mounted loop has a frame to draw; the poster is drawn only until then.
    @State private var isLoopReady = false

    init(
        item: ClipListItem, side: CGFloat, viewModel: ClipListViewModel, isPlaying: Bool, isHidden: Bool,
        onOpen: @escaping (CGRect, CGImage?, TimeInterval?) -> Void, onTrash: @escaping () -> Void
    ) {
        self.item = item
        self.side = side
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.isPlaying = isPlaying
        self.isHidden = isHidden
        self.onOpen = onOpen
        self.onTrash = onTrash
        _playback = StateObject(wrappedValue: ClipCardPlayback(
            asset: viewModel.sourceAsset,
            loadComposition: { [viewModel] geometry in await viewModel.videoComposition(for: geometry) },
            loadDuration: { [viewModel] in await viewModel.assetDuration() }))
    }

    var body: some View {
        GeometryReader { proxy in
            media
                .frame(width: side, height: side)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { open(frame: proxy.frame(in: .global)) }
                // The card's element is the picture itself, so its frame is the card's; the
                // trash button over it stays an element of its own.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                // The timeline's own words: the bar drawn over the picture has no other way to
                // be heard.
                .accessibilityValue(timelineDescription)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the clip in the editor")
                .accessibilityAction(
                    named: Text(ClipListAccessibility.trashActionName(isTrashed: false, isOriginal: false)), onTrash)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) { savedBadge }
        .overlay(alignment: .topTrailing) { trashButton }
        .overlay(alignment: .bottom) { timeline }
        .opacity(isHidden ? 0 : 1)
        // Keyed by the geometry, not the item: a name given doesn't touch the loop, an editor
        // commit that changes the window or the framing rebuilds it.
        .task(id: playbackGeometry) {
            if isPlaying {
                playback.start(geometry: playbackGeometry, isSuspended: false)
            } else {
                playback.prepare(geometry: playbackGeometry)
            }
            async let image = viewModel.thumbnail(for: item)
            async let assetDuration = viewModel.assetDuration()
            thumbnail = await image
            duration = await assetDuration
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                playback.setSuspended(false)
            } else {
                playback.prepare(geometry: playbackGeometry)
            }
        }
        // A rebuilt loop is a new player with no frame yet: the poster comes back until it has one.
        .onChange(of: playback.loop.map { ObjectIdentifier($0.player) }) { _ in isLoopReady = false }
        .onDisappear { playback.teardown() }
    }

    private var playbackGeometry: ClipCardPlaybackGeometry {
        ClipCardPlaybackGeometry(
            window: item.window, cropRect: item.cropRect, cropAdjustment: item.cropAdjustment,
            framingMode: item.framingMode, followCrop: item.followCrop, personID: item.personID)
    }

    @ViewBuilder
    private var media: some View {
        ZStack {
            if !isLoopReady {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.quaternarySystemFill).overlay { ProgressView() }
                }
            }
            if let loop = playback.loop {
                BareVideoPlayerView(
                    player: loop.player, videoGravity: .resizeAspectFill, onReadyForDisplay: { isLoopReady = true })
            }
        }
    }

    /// Pauses the loop first, then reads its position: the frame handed to the editor's flight has
    /// to be the one the card keeps showing until it is hidden.
    private func open(frame: CGRect) {
        playback.setSuspended(true)
        let loopTime = playback.loop.map { $0.player.currentTime() }
        onOpen(frame, thumbnail, loopTime.flatMap { $0.isNumeric ? $0.seconds : nil })
    }

    private static let iconDiameter: CGFloat = 32

    private var trashButton: some View {
        Button(action: onTrash) {
            ZStack {
                Circle().fill(Color.black.opacity(0.45))
                Image(systemName: "trash")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.iconDiameter, height: Self.iconDiameter)
            .touchTarget(insetBy: 6)
        }
        .buttonStyle(.plain)
        .padding(8)
        .accessibilityLabel("Discard clip")
        .accessibilityIdentifier("name-clips-trash")
    }

    /// Marks a clip already in Photos — only ever on screen after a save that partly failed, which
    /// leaves the screen up on a mix of landed and missing clips; a retry saves only the missing.
    @ViewBuilder
    private var savedBadge: some View {
        if item.isSaved {
            ZStack {
                Circle().fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.iconDiameter, height: Self.iconDiameter)
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if let duration {
            ClipRangeTimelineView(window: item.window, duration: duration)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.black.opacity(0.35))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let position = viewModel.clipPosition(of: item)
        var label = ClipListAccessibility.cardLabel(
            clipNumber: position?.number, clipCount: position?.count ?? 0,
            spokenDuration: ClipDurationFormatter.accessibilityString(
                from: item.window.endTime - item.window.startTime),
            isTrashed: false, hasThumbnail: thumbnail != nil)
        if item.isSaved { label += String(localized: ", saved to Photos") }
        return label
    }

    private var timelineDescription: String {
        duration.map { ClipRangeTimelineView.accessibilityDescription(window: item.window, duration: $0) } ?? ""
    }

    private var accessibilityIdentifier: String {
        viewModel.clipPosition(of: item).map { "clip-card-\($0.number)" } ?? "clip-card"
    }
}
