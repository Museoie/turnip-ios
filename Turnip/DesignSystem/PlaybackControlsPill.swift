import SwiftUI

/// The capsule chrome behind every bare-`AVPlayer` transport control in the app —
/// `VideoScrubBar`'s track-plus-buttons bar, and `ClipEditorView`'s buttons-only
/// pill: one font/padding/background definition both build on. Content (which buttons,
/// how they're spaced) stays with the caller, since a scrub track and a bare button pair
/// aren't the same layout.
struct PlaybackControlsPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.4)))
    }
}

/// A play/pause glyph button for a `PlaybackControlsPill`, styled and labeled
/// consistently wherever bare-player transport controls appear.
struct PlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .foregroundStyle(.white)
        }
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// A mute glyph button for a `PlaybackControlsPill`, styled and labeled consistently
/// wherever bare-player transport controls appear.
struct MuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.white)
        }
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }
}
