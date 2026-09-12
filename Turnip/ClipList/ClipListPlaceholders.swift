import SwiftUI

/// Stand-in destination for the clip editor (issue #18).
///
/// `ClipListView` navigates here when a card is tapped. The real editor — trim handles,
/// live crop preview — lands with #18; this pins the navigation contract (one
/// `ClipListItem` in, edits committed on back-navigation per `docs/UIUX.md` § 4) so the
/// list's wiring compiles and CI stays green in the meantime.
struct ClipEditorPlaceholderView: View {
    let item: ClipListItem

    var body: some View {
        VStack(spacing: 12) {
            Text("Clip editor")
                .font(.title2)
            Text("Per-clip trim and crop editing lands with issue #18.")
                .foregroundStyle(.secondary)
            Text(item.durationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Edit clip")
    }
}

/// Stand-in destination for export confirmation (issue #19).
///
/// Reached from the list's "Export N clips" action with exactly the kept clips. #19 owns
/// the per-clip progress and the result summary; this pins the handoff (kept
/// `[ClipListItem]`) so the action compiles and navigates today.
struct ExportConfirmationPlaceholderView: View {
    let items: [ClipListItem]

    var body: some View {
        VStack(spacing: 12) {
            Text("Export confirmation")
                .font(.title2)
            Text("\(items.count) clip\(items.count == 1 ? "" : "s") ready. Per-clip progress and"
                + " the result summary land with issue #19.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle("Export")
    }
}
