import AVFoundation
import SwiftUI

/// A video surface with no playback chrome — just the decoded frames.
///
/// SwiftUI's `VideoPlayer` always draws AVKit's transport controls and there is no
/// public way to hide them, so surfaces that draw their own chrome or none (Processing,
/// the clip list's tiles, the editor, the expansion card) wrap `AVPlayerLayer` directly instead.
struct BareVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// Called on the main thread when the layer has its first frame ready to draw — the
    /// layer is transparent until then. An expansion flight uses this to start only once
    /// the card's video surface can actually show the frame it's meant to start on.
    var onReadyForDisplay: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        configure(view.playerLayer)
        context.coordinator.onReadyForDisplay = onReadyForDisplay
        context.coordinator.observe(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        configure(uiView.playerLayer)
        context.coordinator.onReadyForDisplay = onReadyForDisplay
    }

    private func configure(_ layer: AVPlayerLayer) {
        if layer.player !== player {
            layer.player = player
        }
        layer.videoGravity = videoGravity
        // `AVPlayerLayer` opts into extended dynamic range by default on an EDR-capable
        // display, which reads as blown-out/too-bright on ordinary (non-HDR-graded)
        // clips compared to the SDR thumbnail and the Photos app's player — disable it
        // so playback matches what the still frame and the system player show.
        if #available(iOS 17.0, *) {
            layer.wantsExtendedDynamicRangeContent = false
        }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        // `unsafeDowncast` rather than `as!`: the cast is guaranteed by the `layerClass`
        // override above, not by a runtime check a lint rule should flag.
        var playerLayer: AVPlayerLayer { unsafeDowncast(layer, to: AVPlayerLayer.self) }
    }

    /// Holds the readiness observation for the view's lifetime and forwards it to the
    /// latest `onReadyForDisplay` the representable was given.
    final class Coordinator {
        var onReadyForDisplay: (() -> Void)?
        private var observation: NSKeyValueObservation?

        func observe(_ layer: AVPlayerLayer) {
            observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { self?.onReadyForDisplay?() }
            }
        }
    }
}
