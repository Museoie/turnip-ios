import AVFoundation
import Photos
import SwiftUI

/// Why a saved clip's video couldn't be loaded for reasons of its own: the video left Photos. Other
/// failures are the resolver's `VideoResolutionError`, which names an iCloud download failure.
enum LibraryClipMediaError: Error, Equatable {
    case notInPhotos
}

/// Loads a saved clip's video to play, reporting an iCloud download's 0…1 fraction as it goes.
typealias LoadLibraryClipVideo = @MainActor (
    _ clip: LibraryClip, _ onDownloadProgress: @escaping @Sendable (Double) -> Void
) async throws -> AVAsset

/// A saved clip's video, reached in Photos by its `exportAssetID`. A clip whose video was deleted
/// in Photos keeps its record (`docs/PROFILE_DESIGN.md` §2.3), so every read here can find nothing.
enum LibraryClipMedia {
    static func asset(for clip: LibraryClip) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [clip.exportAssetID], options: nil).firstObject
    }

    /// One final-quality frame, filling `pixelSize`.
    static func thumbnail(for asset: PHAsset, pixelSize: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The production `LoadLibraryClipVideo`: the same `PhotoVideoResolver` a picked video goes
    /// through, so an iCloud-only clip downloads with its progress reported and a failed download
    /// is named as one.
    static func loadVideo(
        _ clip: LibraryClip, onDownloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVAsset {
        guard let asset = asset(for: clip) else { throw LibraryClipMediaError.notInPhotos }
        return try await PhotoVideoResolver().resolve(asset) { progress in
            if case .downloading(let fraction) = progress { onDownloadProgress(fraction) }
        }
    }
}

/// A saved clip's still: its first frame from Photos, a "not in Photos" glyph once the video is
/// gone, or a failure glyph when the video is there but its frame didn't come. Fills whatever
/// frame its caller gives it.
struct LibraryClipThumbnail: View {
    let clip: LibraryClip

    enum Still: Equatable {
        case loading
        case frame(UIImage)
        case notInPhotos
        /// The video is in Photos but no frame came back, typically a failed iCloud fetch. The
        /// tile asks again when it next appears.
        case unavailable
    }

    @Environment(\.displayScale) private var displayScale
    @State private var still = Still.loading
    /// The asset `still` describes. A tile reused for another clip starts over rather than
    /// showing the previous clip's frame; one that only reappears keeps its frame.
    @State private var shownAssetID: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.quaternarySystemFill)
                switch still {
                case .loading:
                    EmptyView()
                case .frame(let image):
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                case .notInPhotos:
                    glyph("video.slash")
                case .unavailable:
                    glyph("exclamationmark.icloud")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: clip.exportAssetID) {
                if shownAssetID != clip.exportAssetID {
                    still = .loading
                    shownAssetID = clip.exportAssetID
                }
                if case .frame = still { return }
                guard let asset = LibraryClipMedia.asset(for: clip) else {
                    still = .notInPhotos
                    return
                }
                let side = max(proxy.size.width, proxy.size.height) * displayScale
                let loaded = await LibraryClipMedia.thumbnail(for: asset, pixelSize: CGSize(width: side, height: side))
                guard shownAssetID == clip.exportAssetID else { return }
                still = Self.still(loaded: loaded, isInPhotos: LibraryClipMedia.asset(for: clip) != nil)
            }
        }
    }

    /// What a finished frame request leaves on the tile. A request that returned nothing because
    /// the video left Photos meanwhile shows as gone, not as a failed fetch.
    static func still(loaded: UIImage?, isInPhotos: @autoclosure () -> Bool) -> Still {
        if let loaded { return .frame(loaded) }
        return isInPhotos() ? .unavailable : .notInPhotos
    }

    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title3)
            .foregroundStyle(.secondary)
    }
}

/// Loops a saved clip's video, muted, over its still until the first frame is ready. Plays on its
/// own only where the system allows auto-playing loops (`mayAutoplayVideoLoops`); otherwise it
/// waits on its first frame for the play button. While an iCloud-only clip downloads it says so
/// with the download's progress, and a failed download says that, with a way to try again.
struct LibraryClipPlayer: View {
    let clip: LibraryClip
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// False for a page beside the current one: its loop is built, paused.
    var isActive = true

    @StateObject private var playback = LibraryClipPlayback()
    @State private var isReady = false

    var body: some View {
        ZStack {
            if !isReady {
                LibraryClipThumbnail(clip: clip)
            }
            if let player = playback.player {
                BareVideoPlayerView(player: player, videoGravity: videoGravity, onReadyForDisplay: { isReady = true })
            }
        }
        .overlay { LibraryClipLoadStatus(phase: playback.phase, retry: retry) }
        .overlay(alignment: .bottomTrailing) {
            if playback.player != nil {
                ScrimIconButton(
                    systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                    accessibilityLabel: playback.isPlaying ? "Pause" : "Play",
                    diameter: 36,
                    font: .footnote.weight(.bold)
                ) {
                    playback.toggle()
                }
                .padding(8)
                .accessibilityIdentifier("clip-play-pause")
            }
        }
        .task(id: clip.exportAssetID) {
            isReady = false
            await playback.load(clip, autoplay: isActive)
        }
        .onChange(of: isActive) { active in
            if active { playback.playIfAllowed() } else { playback.pause() }
        }
        .onDisappear { playback.teardown() }
    }

    private func retry() {
        Task { await playback.load(clip, autoplay: isActive) }
    }
}

/// What a clip's video is doing before it plays, over its still: nothing while it loads from the
/// device, the download's progress while it comes from iCloud, and a failure with "Try Again".
/// A clip whose video left Photos shows its still's own glyph instead.
private struct LibraryClipLoadStatus: View {
    let phase: LibraryClipPlayback.Phase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .downloading(let fraction):
            VStack(spacing: 8) {
                Text("Downloading from iCloud…")
                    .font(.footnote)
                ProgressView(value: fraction)
                    .tint(.white)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: 220)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityValue(ProfileAccessibility.downloadValue(fraction))
            .accessibilityIdentifier("clip-downloading")
        case .failed(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.icloud")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: retry)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("clip-load-retry")
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: 260)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("clip-load-failed")
        case .loading, .ready, .notInPhotos:
            EmptyView()
        }
    }
}

/// The loop behind `LibraryClipPlayer`, and where its video is on the way to playing.
@MainActor
final class LibraryClipPlayback: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// An iCloud download in flight, with PhotoKit's 0…1 fraction.
        case downloading(Double)
        case ready
        case notInPhotos
        /// The load failed for a reason the user can read; a retry starts over.
        case failed(String)
    }

    @Published private(set) var player: AVQueuePlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var phase: Phase = .loading

    private var looper: AVPlayerLooper?
    /// Identifies the load in flight, so a late progress report or result from an earlier one
    /// can't overwrite a newer load's phase.
    private var loadToken: UUID?
    private var loadedVideo: AVAsset?
    private let mayAutoplayLoops: @MainActor () -> Bool
    private let loadVideo: LoadLibraryClipVideo

    init(
        mayAutoplayLoops: @escaping @MainActor () -> Bool = {
            mayAutoplayVideoLoops(
                isVideoAutoplayEnabled: UIAccessibility.isVideoAutoplayEnabled,
                isReduceMotionEnabled: UIAccessibility.isReduceMotionEnabled)
        },
        loadVideo: @escaping LoadLibraryClipVideo = { try await LibraryClipMedia.loadVideo($0, onDownloadProgress: $1) }
    ) {
        self.mayAutoplayLoops = mayAutoplayLoops
        self.loadVideo = loadVideo
    }

    func load(_ clip: LibraryClip, autoplay: Bool) async {
        teardown()
        let token = UUID()
        loadToken = token
        phase = .loading
        do {
            let video = try await loadVideo(clip) { fraction in
                Task { @MainActor [weak self] in self?.reportDownload(fraction, for: token) }
            }
            guard loadToken == token, !Task.isCancelled else {
                Self.discard(video)
                return
            }
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(sdrAsset: video))
            loadedVideo = video
            player = queuePlayer
            phase = .ready
            if autoplay { playIfAllowed() }
        } catch {
            guard loadToken == token, !(error is CancellationError) else { return }
            if error as? LibraryClipMediaError == .notInPhotos {
                phase = .notInPhotos
            } else {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func playIfAllowed() {
        guard mayAutoplayLoops() else { return }
        play()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        player?.play()
        isPlaying = player != nil
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func teardown() {
        loadToken = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isPlaying = false
        if let loadedVideo { Self.discard(loadedVideo) }
        loadedVideo = nil
    }

    /// A download fraction counts only for the load still in flight and only until it settles.
    private func reportDownload(_ fraction: Double, for token: UUID) {
        guard loadToken == token else { return }
        switch phase {
        case .loading, .downloading: phase = .downloading(fraction)
        case .ready, .notInPhotos, .failed: break
        }
    }

    /// An edited clip resolves to a composition exported into `tmp/`; that file is this player's
    /// to remove once it's done with it.
    private static func discard(_ video: AVAsset) {
        if let urlAsset = video as? AVURLAsset { PhotoVideoResolver.deleteTemporaryExport(for: urlAsset) }
    }
}
