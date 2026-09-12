import SwiftUI

/// Stand-in destination for the clip editor.
///
/// `ClipListView` navigates here when a card is tapped. The real editor — trim handles,
/// live crop preview — lands with the follow-up editor PR; this pins the navigation
/// contract (a binding into the list item, so edits commit on back-navigation per
/// `docs/UIUX.md` § "Clip Detail / Editor") so the list's wiring compiles and CI stays green in
/// the meantime.
struct ClipEditorPlaceholderView: View {
    @Binding var item: ClipListItem

    var body: some View {
        VStack(spacing: 12) {
            Text("Clip editor")
                .font(.title2)
            Text("Per-clip trim and crop editing lands with the follow-up editor PR.")
                .foregroundStyle(.secondary)
            Text(item.durationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Edit clip")
    }
}

/// Stand-in destination for export confirmation.
///
/// Reached from the list's "Export N clips" action with exactly the kept clips. The
/// follow-up export PR owns the per-clip progress and the result summary; this pins
/// the handoff (kept `[ClipListItem]`) so the action compiles and navigates today.
struct ExportConfirmationPlaceholderView: View {
    let items: [ClipListItem]

    var body: some View {
        VStack(spacing: 12) {
            Text("Export confirmation")
                .font(.title2)
            Text("\(items.count) clip\(items.count == 1 ? "" : "s") ready. Per-clip progress and"
                + " the result summary land with the follow-up export PR.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle("Export")
    }
}
