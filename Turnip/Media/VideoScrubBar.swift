import AVFoundation
import SwiftUI

/// A thin playback bar for a bare `AVPlayer` surface: play/pause, a draggable scrub
/// track, and a mute toggle. Pairs with `BareVideoPlayerView`, which has no transport
/// controls of its own (`docs/UIUX.md` § "Processing").
struct VideoScrubBar: View {
    let player: AVPlayer
    /// Reports every scrub start/end to the caller — `ProcessingView` uses it to keep its own
    /// swipe-to-browse gesture from also acting on a drag that's scrubbing this track.
    var onScrubbingChanged: ((Bool) -> Void)? = nil

    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var duration: TimeInterval = 0
    @State private var currentTime: TimeInterval = 0
    @State private var isScrubbing = false
    /// Whether the player was actually playing (`player.rate != 0`, not the possibly-stale
    /// `isPlaying`) the instant a scrub began, so letting go resumes only when it should.
    @State private var wasPlayingBeforeScrub = false
    @State private var timeObserver: Any?
    @State private var didEndObserver: NSObjectProtocol?

    fileprivate static let trackHeight: CGFloat = 3

    var body: some View {
        PlaybackControlsPill {
            HStack(spacing: 12) {
                PlayPauseButton(isPlaying: isPlaying, action: togglePlayback)
                track
                    .frame(height: Self.trackHeight)
                MuteButton(isMuted: isMuted, action: toggleMute)
            }
        }
        .task { attach() }
        .onDisappear { detach() }
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: width * fraction)
            }
            .contentShape(Rectangle().inset(by: -10)) // Widens the drag target past the thin visual track.
            // `.highPriorityGesture`, not `.gesture`: this needs to fire regardless of
            // `ProcessingView`'s own swipe gesture on an ancestor, which runs simultaneously
            // with this one rather than competing for it (see that gesture's own doc comment).
            // A 0pt `minimumDistance`, well under the ancestor's 20pt, is what lets
            // `onScrubbingChanged(true)` reach it before its gesture would otherwise act.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            wasPlayingBeforeScrub = player.rate != 0
                            if wasPlayingBeforeScrub {
                                player.pause()
                                isPlaying = false
                            }
                            onScrubbingChanged?(true)
                        }
                        let scrubbedFraction = min(max(value.location.x / width, 0), 1)
                        currentTime = scrubbedFraction * duration
                        seek(to: currentTime)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        if wasPlayingBeforeScrub {
                            player.play()
                            isPlaying = true
                        }
                        onScrubbingChanged?(false)
                    }
            )
        }
    }

    private func togglePlayback() {
        isPlaying.toggle()
        if isPlaying { player.play() } else { player.pause() }
    }

    private func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    private func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func attach() {
        isMuted = player.isMuted
        isPlaying = player.rate != 0
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            // Duration isn't known until the item loads, so this polls it alongside
            // the current time rather than watching `currentItem.status` separately.
            let seconds = player.currentItem?.duration.seconds ?? 0
            duration = seconds.isFinite && seconds > 0 ? seconds : 0
            guard !isScrubbing else { return }
            currentTime = time.seconds
        }
        // Reaching the end pauses the player (`AVPlayer`'s default `actionAtItemEnd`) rather
        // than looping on its own — restart it from the top, Photos-app style, instead of
        // leaving the last frame frozen.
        didEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
        ) { _ in
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            isPlaying = true
        }
    }

    private func detach() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let didEndObserver {
            NotificationCenter.default.removeObserver(didEndObserver)
        }
        didEndObserver = nil
    }
}

extension VideoScrubBar {
    /// The bar's resting look with no player behind it — playing, nothing scrubbed, unmuted,
    /// exactly as a freshly arrived video's real bar first draws. For a page that stands in
    /// for a screen not yet there (Processing's neighbor pages mid-swipe), so the real bar
    /// replaces it in place with no visible change. Inert by construction: the buttons do
    /// nothing, and the caller is expected to keep it out of hit-testing.
    struct Placeholder: View {
        var body: some View {
            PlaybackControlsPill {
                HStack(spacing: 12) {
                    PlayPauseButton(isPlaying: true) {}
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(height: VideoScrubBar.trackHeight)
                    MuteButton(isMuted: false) {}
                }
            }
        }
    }
}
