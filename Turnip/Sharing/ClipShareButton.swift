import SwiftUI

/// The v2 Share Sheet action for one exported clip (issue #12;
/// `docs/DESIGN.md` § "Publishing to social media (iOS Share Sheet)").
///
/// A thin wrapper around SwiftUI's `ShareLink` (iOS 16+, the repo's deployment floor):
/// Turnip hands the exported clip's file URL to the system share sheet, iOS enumerates
/// every installed app that accepts a video — Instagram, TikTok, YouTube Shorts,
/// Messages, Photos, AirDrop — and the target app owns the compose step. Zero server
/// involvement, per the design doc. `UIActivityViewController` was the issue's fallback
/// if `ShareLink` proved too limited; it isn't — this flow needs no excluded activity
/// types, no custom UI, and no completion callback, so a `UIViewControllerRepresentable`
/// wrapper would buy nothing.
///
/// Built only on Foundation/SwiftUI types so it compiles standalone on `main`, following
/// the same standalone-contract convention as the #17/#18/#19 screens: the Export
/// Confirmation screen's saved-clip rows (PR #65) and/or Clip Detail (PR #64) adopt this
/// once those merge.
///
/// The caller owns the file's lifetime: the URL must keep pointing at an existing file
/// from when this view appears until the share sheet dismisses. In particular, the
/// Export Confirmation screen's run-end scratch-directory cleanup (see issue #23) has to
/// move to screen dismissal before this button is wired in there — otherwise the sheet
/// offers a file that is already gone.
struct ClipShareButton: View {
    /// The exported clip's file URL. Must be a `file://` URL: a remote URL would share a
    /// link rather than the video, which defeats the design doc's whole point — the OS
    /// moves the on-device file, no CDN staging.
    let fileURL: URL
    /// The clip's display title (e.g. "Clip 1 · 2.4s"); becomes the share subject, e.g.
    /// the subject line when the destination is Mail.
    let clipTitle: String

    var body: some View {
        ShareLink(item: fileURL, subject: Text(clipTitle)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        // A share sheet for a missing file fails at every destination with no useful
        // error, so the button refuses to present one instead of offering it.
        .disabled(!Self.isShareable(fileURL: fileURL))
    }

    /// Whether the share sheet can actually hand this URL off: it must be a file URL
    /// and the file must exist right now. `static` rather than inline in `body` so tests
    /// can assert on the exact guard — a view-level test can't distinguish "sheet
    /// presented" from "sheet presented over a missing file".
    static func isShareable(fileURL: URL) -> Bool {
        fileURL.isFileURL && FileManager.default.fileExists(atPath: fileURL.path)
    }
}

#Preview("Share button") {
    // The preview writes a real (empty) file so the button renders in its enabled
    // state; a missing file would preview the disabled guard instead.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("turnip-share-preview.mp4")
    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    return ClipShareButton(fileURL: url, clipTitle: "Clip 1 · 2.4s")
}
