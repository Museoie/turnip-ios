#if DEBUG
import AVFoundation
import SwiftUI

/// UI-test screenshot harness for the export confirmation screen.
///
/// Shown only when the app is launched with `-screenshotExportConfirmation` (holds
/// the first clip mid-export at 50% so the screenshot shows the progress UI) or
/// `-screenshotExportConfirmationFinished` (the run completes instantly so the
/// screenshot shows the summary). Driven by `TurnipUITests/ScreenshotTests.swift`;
/// unreachable in normal use and compiled out of release builds.
struct ScreenshotHarness: View {
    let finishImmediately: Bool

    var body: some View {
        NavigationStack {
            ExportConfirmationView(
                items: [
                    ExportConfirmationItem(
                        window: TrickWindow(startTime: 2, endTime: 5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                    ExportConfirmationItem(
                        window: TrickWindow(startTime: 9, endTime: 11.5),
                        cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
                ],
                asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
                exportClip: { _, _, _, _, progress in
                    if finishImmediately {
                        progress(1.0)
                    } else {
                        // Hold the run mid-export: the UI test screenshots the
                        // progress state, then the test runner kills the app.
                        progress(0.5)
                        try await Task.sleep(for: .seconds(60))
                    }
                    return URL(fileURLWithPath: "/tmp/screenshot-clip.mp4")
                },
                saveToPhotos: { _ in }
            )
        }
    }
}
#endif
