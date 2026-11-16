import AVFoundation
import SwiftUI
import UIKit

/// One clip at a fixed size, as a Clip List tile and as a Name Clips page's card (`Placement`): its
/// window looping with the framing export uses through `ClipCardPlayback`, over its poster until
/// the loop has a frame. A card that isn't playing builds its loop paused on the first frame, so a
/// page beside the current one slides in showing the video it is about to play rather than a
/// poster that cuts to it.
///
/// The card also carries the saved-to-Photos badge and the read-only timeline of where the
/// window sits in the video. A tap on a page flies the card open into the editor from where it
/// sits; a tap on a tile opens Name Clips on its clip.
///
/// The card's size comes from its caller and never from its content: a poster drawn
/// `scaledToFill` overflows whatever proposes its size, so the frame is fixed first and the
/// picture is clipped to it.
struct ClipCard: View {
    /// Where the card is shown, which decides what a tap on it opens and what it is called.
    enum Placement {
        /// A Name Clips page: a tap opens the editor. Its identifier is `clip-card-N`.
        case page
        /// A Clip List tile: a tap opens Name Clips on the clip, or marks it while the grid is
        /// selecting (`selection`), and VoiceOver reads the names it has been given. Its
        /// identifier is `clip-tile-N`.
        case tile
    }

    let item: ClipListItem
    let side: CGFloat
    let placement: Placement
    @ObservedObject var viewModel: ClipListViewModel
    /// Whether the loop may play: the page is the current one, or the tile's list is on screen,
    /// and nothing covers it. A card that isn't playing keeps its loop, paused.
    let isPlaying: Bool
    /// True for the card whose clip is open in the editor; the flying card stands in for it.
    let isHidden: Bool
    /// Whether the tile is marked, while its grid is selecting; `nil` otherwise, and on a page. A
    /// selecting tile's tap marks it rather than leaving, so its loop plays on.
    let selection: Bool?
    /// The tap: hands over the card's on-screen frame (global space), and the poster and the
    /// asset time the loop was showing (`nil` without a loop), which the editor's flight opens
    /// from. A tile's tap needs none of them.
    let onOpen: (CGRect, CGImage?, TimeInterval?) -> Void
    /// The swipe's way to the clip before and after this one, as VoiceOver actions on the card
    /// itself, beside the bar's Previous and Next. `nil` where there is no clip that way, or on a
    /// card that isn't the current page.
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?

    @StateObject private var playback: ClipCardPlayback
    @State private var thumbnail: CGImage?
    @State private var duration: TimeInterval?
    /// Whether the mounted loop has a frame to draw; the poster is drawn only until then.
    @State private var isLoopReady = false

    init(
        item: ClipListItem, side: CGFloat, placement: Placement, viewModel: ClipListViewModel, isPlaying: Bool,
        isHidden: Bool = false, selection: Bool? = nil, onOpen: @escaping (CGRect, CGImage?, TimeInterval?) -> Void,
        onPrevious: (() -> Void)? = nil, onNext: (() -> Void)? = nil
    ) {
        self.item = item
        self.side = side
        self.placement = placement
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.isPlaying = isPlaying
        self.isHidden = isHidden
        self.selection = selection
        self.onOpen = onOpen
        self.onPrevious = onPrevious
        self.onNext = onNext
        // The poster another card already decoded — the tile a page was opened from — is on screen
        // from the first frame, rather than a placeholder for the moment the `.task` takes to ask.
        _thumbnail = State(initialValue: viewModel.cachedThumbnail(for: item))
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
                // The card's element is the picture itself, so its frame is the card's.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                // The timeline's own words: the bar drawn over the picture has no other way to
                // be heard.
                .accessibilityValue(timelineDescription)
                .accessibilityAddTraits(selection == true ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(accessibilityHint)
                .accessibilityActions {
                    if let onPrevious { Button("Previous clip", action: onPrevious) }
                    if let onNext { Button("Next clip", action: onNext) }
                }
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) { savedBadge }
        .overlay(alignment: .bottom) { timeline }
        .overlay(alignment: .topTrailing) { selectionMark }
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
        // Either accessibility setting can flip while the app is backgrounded — changing
        // one requires leaving the app — and a mounted tile gets no onAppear or .task(id:)
        // re-fire on return, so the gate would never be re-read and the loop would keep
        // playing against the new setting (#198). Re-evaluate on both change
        // notifications, and again on foregrounding in case one posted while the app was
        // backgrounded and was never delivered to this view.
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIAccessibility.videoAutoplayStatusDidChangeNotification)
        ) { _ in playback.accessibilitySettingsChanged() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIAccessibility.reduceMotionStatusDidChangeNotification)
        ) { _ in playback.accessibilitySettingsChanged() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in playback.accessibilitySettingsChanged() }
        .onDisappear { playback.teardown() }
    }

    private var playbackGeometry: ClipCardPlaybackGeometry {
        ClipCardPlaybackGeometry(
            window: item.window, cropRect: item.cropRect, followCrop: item.followCrop, personID: item.personID)
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
    /// to be the one the card keeps showing until it is hidden. A selecting tile only marks.
    private func open(frame: CGRect) {
        guard selection == nil else {
            onOpen(frame, thumbnail, nil)
            return
        }
        playback.setSuspended(true)
        let loopTime = playback.loop.map { $0.player.currentTime() }
        onOpen(frame, thumbnail, loopTime.flatMap { $0.isNumeric ? $0.seconds : nil })
    }

    private static let iconDiameter: CGFloat = 32

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

    /// While the grid is selecting, the check circle Photos and the Profile's trick grid draw, and
    /// a light wash over a marked tile. It takes no tap: the tile's own tap marks.
    @ViewBuilder
    private var selectionMark: some View {
        if let selection {
            ZStack(alignment: .topTrailing) {
                if selection {
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.25))
                }
                Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, selection ? Color.accentColor : Color.black.opacity(0.3))
                    .padding(8)
            }
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
            hasThumbnail: thumbnail != nil)
        if item.isSaved { label += String(localized: ", saved to Photos") }
        // A page's names are the chips under it; a tile's are only in its caption, which
        // VoiceOver skips.
        if placement == .tile, !item.names.isEmpty {
            label += ", " + ClipListAccessibility.namesLabel(item.names.map(\.name))
        }
        return label
    }

    private var accessibilityHint: LocalizedStringKey {
        switch placement {
        case .page: return "Opens the clip in the editor"
        case .tile: return selection == nil ? "Opens the clip to name it" : "Marks the clip for deleting"
        }
    }

    private var timelineDescription: String {
        duration.map { ClipRangeTimelineView.accessibilityDescription(window: item.window, duration: $0) } ?? ""
    }

    private var accessibilityIdentifier: String {
        let prefix = placement == .page ? "clip-card" : "clip-tile"
        return viewModel.clipPosition(of: item).map { "\(prefix)-\($0.number)" } ?? prefix
    }
}
