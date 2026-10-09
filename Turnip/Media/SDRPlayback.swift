import AVFoundation

extension AVPlayerItem {
    /// An item that renders like the thumbnail and the Photos app, not like an
    /// unmodified HDR/Dolby Vision decode.
    ///
    /// iPhone video is commonly HDR-graded (on-by-default "HDR Video" camera capture),
    /// and by default AVFoundation applies its embedded per-frame HDR display metadata
    /// during playback — which renders visibly brighter/blown-out than the SDR still
    /// `AVAssetImageGenerator` produces for the thumbnail, or than a player that tone
    /// maps it down. `appliesPerFrameHDRDisplayMetadata = false` opts the item out of
    /// that per-frame boost so playback matches the still frame.
    convenience init(sdrAsset asset: AVAsset) {
        self.init(asset: asset)
        appliesPerFrameHDRDisplayMetadata = false
    }
}
