import SwiftUI

/// Configuration screen (`docs/UIUX.md` § "Settings"): the four preferences the app exposes,
/// each taking effect the next time its integration point runs rather than needing a restart —
/// analysis mode on the next Record tap, the album on the next save, granularity on the next
/// analysis run. Presented as a sheet from Home's gear button rather than pushed onto the main
/// flow's `NavigationStack`, since it isn't part of "pick a video, get clips" and has nothing to
/// hand back to that flow.
struct SettingsView: View {
    @ObservedObject var settings: TurnipSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Analysis mode", selection: $settings.analysisMode) {
                        ForEach(AnalysisMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings-analysis-mode")
                } header: {
                    Text("Camera")
                } footer: {
                    Text("""
                        Real-time scores pose while you record and skips analysis for a take \
                        it fully covers. Offline always analyzes after you stop recording.
                        """)
                }

                Section {
                    Toggle("Save to an album", isOn: $settings.autoAddToAlbum)
                        .accessibilityIdentifier("settings-auto-add-album")
                    if settings.autoAddToAlbum {
                        TextField("Album name", text: $settings.albumName)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("settings-album-name")
                    }
                } header: {
                    Text("Saved clips")
                } footer: {
                    Text("Off saves clips the way Photos saves any new video, with no album.")
                }

                Section {
                    Stepper(
                        "Granularity: \(settings.analysisGranularity)",
                        value: Binding(
                            get: { settings.analysisGranularity },
                            set: { settings.setAnalysisGranularity($0) }),
                        in: TurnipSettings.granularityRange
                    )
                    .accessibilityIdentifier("settings-granularity")
                } header: {
                    Text("Analysis")
                } footer: {
                    Text("""
                        Frames sampled per second of footage. Higher can catch faster motion; \
                        lower analyzes faster. Defaults to \(TurnipSettings.defaultGranularity).
                        """)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
        }
    }
}

#Preview {
    SettingsView(settings: TurnipSettingsStore(defaults: UserDefaults(suiteName: "preview")!))
        .preferredColorScheme(.dark)
}
