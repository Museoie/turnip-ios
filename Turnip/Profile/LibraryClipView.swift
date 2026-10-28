import SwiftUI

/// The Clip view (`docs/PROFILE_DESIGN.md` §5.2): plays a saved clip, shows its names and who is
/// in it for editing, and its date, and deletes it from the library — asking whether its video
/// leaves Photos too. Its window and framing are what export made of them and can't change here.
struct LibraryClipView: View {
    let clipID: UUID
    @ObservedObject var library: ClipLibrary
    @ObservedObject var vocabulary: VocabularyStore
    /// Pops back once the clip is deleted.
    let close: () -> Void

    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool
    @State private var isConfirmingDelete = false
    @State private var deleteFailure: String?

    var body: some View {
        Group {
            if let clip = library.clip(clipID) {
                content(for: clip)
            } else {
                Text("This clip is no longer in your Profile.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("clip-view")
        .onDisappear(perform: commitDraft)
        .errorAlert("Couldn't delete the video", message: $deleteFailure)
    }

    private var title: String {
        guard let clip = library.clip(clipID), !clip.names.isEmpty else { return String(localized: "Clip") }
        return clip.names.map(\.name).joined(separator: " + ")
    }

    private func content(for clip: LibraryClip) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LibraryClipPlayer(clip: clip)
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Clip video"))
                Text(details(of: clip))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clip-view-date")
                ClipNamingFields(
                    names: clip.names, isMe: clip.isMe, usedNames: library.namesUsed(alongside: clip),
                    vocabulary: vocabulary.current, draft: $draft, isFieldFocused: $isFieldFocused,
                    isEnabled: true, commitDraft: commitDraft, actions: actions(for: clip.id))
                Button(role: .destructive) {
                    commitDraft()
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Clip", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                // On the button, so where the dialog shows as a popover it points at what was tapped.
                .confirmationDialog("Delete this clip?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                    Button("Remove from Profile", role: .destructive) { delete(clip, alsoFromPhotos: false) }
                    if LibraryClipMedia.asset(for: clip) != nil {
                        Button("Remove and Delete Video from Photos", role: .destructive) {
                            delete(clip, alsoFromPhotos: true)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("What this clip earned stays earned.")
                }
                .padding(.top, 8)
                .accessibilityIdentifier("clip-view-delete")
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// "Recorded 27 Oct 2026 at 3:41 PM · 1.5s".
    private func details(of clip: LibraryClip) -> String {
        let date = clip.recordedAt.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Recorded \(date) · \(ClipDurationFormatter.string(from: clip.duration))")
    }

    private func actions(for id: UUID) -> ClipNamingActions {
        ClipNamingActions(
            add: { library.addName($0, origin: $1, to: id) },
            remove: { library.removeName($0, from: id) },
            replace: { library.replaceName($0, with: $1, in: id) },
            setIsMe: { library.setIsMe($0, for: id) })
    }

    /// A name typed and left without pressing return still counts as given.
    private func commitDraft() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        library.addName(draft, origin: .typed, to: clipID)
        draft = ""
    }

    /// Removes the clip, after its video when that goes too. A video Photos didn't delete — the
    /// user declined its confirmation — keeps the clip as well.
    private func delete(_ clip: LibraryClip, alsoFromPhotos: Bool) {
        Task {
            if alsoFromPhotos {
                do {
                    try await PhotoAssetDeleter().delete(assetIdentifier: clip.exportAssetID)
                } catch {
                    deleteFailure = error.localizedDescription
                    return
                }
            }
            library.delete(clip.id)
            close()
        }
    }
}
