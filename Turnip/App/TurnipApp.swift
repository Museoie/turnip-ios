import SwiftUI

@main
struct TurnipApp: App {
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if CommandLine.arguments.contains("-screenshotExportConfirmationFinished") {
                    ScreenshotHarness(finishImmediately: true)
                } else if CommandLine.arguments.contains("-screenshotExportConfirmation") {
                    ScreenshotHarness(finishImmediately: false)
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
        }
    }
}
