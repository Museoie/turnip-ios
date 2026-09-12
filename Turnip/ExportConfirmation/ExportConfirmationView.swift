import AVFoundation
import SwiftUI

/// The export confirmation screen (`docs/UIUX.md` § "Export Confirmation").
///
/// Reached from the clip list's "Export N clips" action with the kept clips. Starts the
/// export on appear, shows per-clip progress as each clip exports and saves to Photos,
/// and ends in a summary — "N of M clips saved to Photos" with per-clip failures named
/// individually. `Done` dismisses back to the list; per the design doc there is no further
/// action, the user starts over from Home. The Share Sheet hooks in here in v2.
///
/// This view deliberately declares no `NavigationStack` of its own — it lives on the
/// flow's shared stack, like the clip list.
struct ExportConfirmationView: View {
    @StateObject private var viewModel: ExportConfirmationViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        items: [ExportConfirmationItem],
        asset: AVAsset,
        exportClip: @escaping ExportOneClip,
        saveToPhotos: @escaping SaveOneClipToPhotos
    ) {
        _viewModel = StateObject(wrappedValue: ExportConfirmationViewModel(
            items: items,
            asset: asset,
            exportClip: exportClip,
            saveToPhotos: saveToPhotos))
    }

    var body: some View {
        List {
            if viewModel.isFinished {
                summarySection
            }
            Section("Clips") {
                ForEach(viewModel.clips) { clip in
                    ClipStatusRow(clip: clip)
                }
            }
        }
        .navigationTitle("Export")
        .navigationBarBackButtonHidden(viewModel.isRunning)
        .toolbar {
            if viewModel.isRunning {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancel() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.isFinished {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.thinMaterial)
            }
        }
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    /// The final state: the "N of M clips saved to Photos" summary plus each failure
    /// called out individually, per `docs/UIUX.md` § "Export Confirmation".
    @ViewBuilder
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: summaryIconName)
                        .foregroundStyle(summaryIconColor)
                    Text(viewModel.summaryText ?? "")
                        .font(.headline)
                }
                .accessibilityElement(children: .combine)
                ForEach(viewModel.failures, id: \.title) { failure in
                    Text("\(failure.title) — \(failure.reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var summaryIconName: String {
        if viewModel.wasCancelled || !viewModel.failures.isEmpty {
            "exclamationmark.triangle.fill"
        } else {
            "checkmark.circle.fill"
        }
    }

    private var summaryIconColor: Color {
        if viewModel.wasCancelled || !viewModel.failures.isEmpty {
            .orange
        } else {
            .green
        }
    }
}

/// One clip's row: its title, a status icon, and whatever the phase needs — the export's
/// determinate progress, an indeterminate spinner for the Photos save, or the failure
/// reason in full (the summary's individual callout, not a folded count).
private struct ClipStatusRow: View {
    let clip: ExportConfirmationViewModel.ClipState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(clip.title)
                Spacer()
                statusIcon
            }
            switch clip.phase {
            case .exporting(let fraction):
                ProgressView(value: fraction) {
                    Text("Exporting…")
                }
            case .saving:
                ProgressView {
                    Text("Saving to Photos…")
                }
            case .failed(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .pending, .saved:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.title), \(phaseDescription)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch clip.phase {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .exporting, .saving:
            EmptyView()
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var phaseDescription: String {
        switch clip.phase {
        case .pending:
            "waiting"
        case .exporting(let fraction):
            "exporting, \(Int((fraction * 100).rounded())) percent"
        case .saving:
            "saving to Photos"
        case .saved:
            "saved"
        case .failed(let reason):
            "failed: \(reason)"
        }
    }
}

#Preview("Export confirmation") {
    NavigationStack {
        ExportConfirmationView(
            items: [
                ExportConfirmationItem(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
                ExportConfirmationItem(
                    window: TrickWindow(startTime: 9, endTime: 11.5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)),
            ],
            // AVURLAsset over /dev/null rather than a bare AVAsset(): the bare
            // initializer aborts the test host ("freed pointer was not the last
            // allocation") while this form runs clean (see the test fixtures
            // and ScreenshotHarness). Previews don't execute in CI, but the safe
            // form avoids anyone copy-pasting the crashing one into a test.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            exportClip: { _, _, _, _, progress in
                progress(0.5)
                progress(1.0)
                return URL(fileURLWithPath: "/tmp/preview-clip.mp4")
            },
            saveToPhotos: { _ in }
        )
    }
}
