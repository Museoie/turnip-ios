import SwiftUI

/// One trick's clips (`docs/PROFILE_DESIGN.md` §7): a grid of the gallery's tiles, newest first,
/// under the filter the gallery had when it opened, with as many columns as Home's grid fits across
/// the same width (`GalleryGrid`). A tile opens the Clip view, which swipes through the grid's clips.
///
/// "Select" turns the grid into a selection, as Photos does: a tile tap marks or unmarks it, the
/// back button stands down until "Cancel", and a bar along the bottom removes the marked clips
/// from the Profile together, asking first whether their videos leave Photos too.
///
/// "Same Trick As…" (`TrickSynonymSheet`) marks this trick as one with another; the screen then
/// shows the two together, under the name the user kept.
struct TrickClipsView: View {
    let trickKey: String
    let filter: TrickGallery.Filter
    @ObservedObject var library: ClipLibrary
    @ObservedObject var vocabulary: VocabularyStore
    /// Pushes the Clip view for a tile, with the grid's clips in its order for the view to swipe
    /// through.
    let open: (_ clip: UUID, _ among: [UUID]) -> Void
    /// Pops back once removing has left no clip of the trick.
    let close: () -> Void

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var removalPrompt: LibraryClipRemovalPrompt?
    @State private var removalFailure: String?
    @State private var isShowingSynonyms = false
    /// The trick "Same Trick As…" was opened for, held while the sheet is up: a merge or a
    /// separate made in it changes `group` under it.
    @State private var synonymSheetTrick: Trick?
    /// The trick this one was merged into on this screen, which it shows from then on.
    @State private var mergedKey: String?
    /// iPhone Duo's vertical bar, which the bar's items go down instead.
    @Environment(\.verticalBar) private var verticalBar

    private var key: String { mergedKey ?? trickKey }

    /// Read from the library each time, so a clip renamed or deleted on the Clip view leaves this
    /// grid when it comes back.
    private var group: TrickGallery.Group? {
        TrickGallery.groups(of: library.clips, filter: filter, vocabulary: vocabulary.current)
            .first { $0.trick.key == key }
    }

    /// Every trick the user's clips resolve to, under either filter, the gallery's order.
    private var ownTricks: [Trick] {
        var seen = Set<String>()
        return TrickGallery.Filter.allCases
            .flatMap { TrickGallery.groups(of: library.clips, filter: $0, vocabulary: vocabulary.current) }
            .map(\.trick)
            .filter { seen.insert($0.key).inserted }
    }

    /// The marked clips still in the grid: one renamed away or deleted meanwhile drops out.
    private var selectedClips: [LibraryClip] {
        group?.clips.filter { selection.contains($0.id) } ?? []
    }

    private var title: String {
        if isSelecting {
            return selectedClips.isEmpty
                ? String(localized: "Select Clips") : String(localized: "\(selectedClips.count) Selected")
        }
        return group?.trick.title ?? Trick(key: key, name: key).title
    }

    var body: some View {
        Group {
            if let group {
                GeometryReader { geometry in
                    ScrollView {
                        let columns = GalleryGrid.columns(forWidth: geometry.size.width)
                        LazyVGrid(columns: columns, spacing: GalleryGrid.spacing) {
                            ForEach(group.clips) { clip in
                                tile(for: clip, in: group)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(
                        ProfileAccessibility.galleryRowLabel(trick: group.trick, count: group.clips.count))
                }
            } else {
                Text("No clips of this trick.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Hidden while selecting, as Photos hides it: "Cancel" is the way out of a selection.
        .navigationBarBackButtonHidden(isSelecting || verticalBar != nil)
        .toolbar {
            if verticalBar == nil, group != nil {
                if !isSelecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: showSynonyms) {
                            Image(systemName: "arrow.triangle.merge")
                        }
                        .accessibilityLabel("Same Trick As…")
                        .accessibilityIdentifier("trick-clips-same-as")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: toggleSelecting) {
                        Text(isSelecting ? "Cancel" : "Select")
                    }
                    .accessibilityIdentifier("trick-clips-select")
                }
            }
        }
        .verticalBarSlotControls(refreshingOn: verticalBarState) { state in
            // The back button stands down while selecting here too.
            if !state.isSelecting {
                ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to Profile", action: close)
                    .accessibilityIdentifier("trick-clips-back")
            }
            if state.hasClips && !state.isSelecting {
                ScrimIconButton(
                    systemImage: "arrow.triangle.merge", accessibilityLabel: "Same Trick As…",
                    action: showSynonyms)
                .accessibilityIdentifier("trick-clips-same-as")
            }
            if state.hasClips {
                // Glyphs here, as the column is too narrow for the bar's words at larger text.
                ScrimIconButton(
                    systemImage: state.isSelecting ? "xmark" : "checkmark.circle",
                    accessibilityLabel: state.isSelecting ? "Cancel" : "Select",
                    action: toggleSelecting)
                .accessibilityIdentifier("trick-clips-select")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                removalBar
            }
        }
        .libraryClipRemovalDialog($removalPrompt, remove: remove)
        .sheet(isPresented: $isShowingSynonyms) {
            if let trick = synonymSheetTrick {
                TrickSynonymSheet(
                    trick: trick, ownTricks: ownTricks, vocabulary: vocabulary,
                    merged: { mergedKey = $0.key }, separated: afterSeparating)
            }
        }
        .errorAlert("Couldn't delete the videos", message: $removalFailure)
        .accessibilityIdentifier("trick-clips")
    }

    /// What the vertical bar's controls show.
    private struct VerticalBarState: Equatable {
        let isSelecting: Bool
        let hasClips: Bool
    }

    private var verticalBarState: VerticalBarState {
        VerticalBarState(isSelecting: isSelecting, hasClips: group != nil)
    }

    /// One button whichever the mode, so a tile keeps its identity, and its loaded still, as the
    /// grid goes in and out of selecting.
    private func tile(for clip: LibraryClip, in group: TrickGallery.Group) -> some View {
        let isSelected = selection.contains(clip.id)
        return Button {
            if isSelecting {
                if isSelected {
                    selection.remove(clip.id)
                } else {
                    selection.insert(clip.id)
                }
            } else {
                open(clip.id, group.clips.map(\.id))
            }
        } label: {
            LibraryClipTile(clip: clip, selection: isSelecting ? isSelected : nil)
        }
        .buttonStyle(.plain)
    }

    private var removalBar: some View {
        let count = selectedClips.count
        let title = count == 0
            ? String(localized: "Delete") : String(localized: "Delete \(ProfileAccessibility.clipCount(count))")
        return Button(role: .destructive) {
            removalPrompt = LibraryClipRemovalPrompt(clips: selectedClips)
        } label: {
            Label(title, systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(count == 0)
        .padding()
        .background(.thinMaterial)
        .accessibilityIdentifier("trick-clips-delete")
    }

    private func showSynonyms() {
        synonymSheetTrick = group?.trick
        isShowingSynonyms = synonymSheetTrick != nil
    }

    /// A separate that leaves the merged trick with none of the user's clips undoes the merge made
    /// here: the grid goes back to the trick it opened on, and the sheet, about the other, closes.
    private func afterSeparating() {
        guard mergedKey != nil, group == nil else { return }
        mergedKey = nil
        isShowingSynonyms = false
    }

    private func toggleSelecting() {
        isSelecting.toggle()
        selection = []
    }

    /// Removes the clips that were marked when Delete was tapped, after their videos when those
    /// go too. Videos Photos didn't delete — the user declined its confirmation — keep every clip
    /// as well, and the selection. With no clip of the trick left the screen goes back; otherwise
    /// the grid leaves selecting.
    private func remove(_ removed: [LibraryClip], alsoFromPhotos: Bool) {
        Task {
            do {
                guard try await LibraryClipRemoval(library: library).remove(removed, alsoFromPhotos: alsoFromPhotos)
                else { return }
            } catch {
                removalFailure = error.localizedDescription
                return
            }
            isSelecting = false
            selection = []
            if group == nil {
                close()
            }
        }
    }
}

/// A gallery tile: the clip's still, its length over a scrim, and a mark on a clip of someone else.
/// While its grid is selecting, a check circle in the bottom corner says whether it's marked.
struct LibraryClipTile: View {
    let clip: LibraryClip
    /// Whether the tile is marked, while its grid is selecting; `nil` otherwise.
    var selection: Bool?

    @State private var isInPhotos = true

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { LibraryClipThumbnail(clip: clip) }
            .overlay {
                if selection == true {
                    Color.white.opacity(0.25)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(ClipDurationFormatter.string(from: clip.duration))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if !clip.isMe {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let selection {
                    Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selection ? Color.accentColor : Color.black.opacity(0.3))
                        .padding(6)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProfileAccessibility.tileLabel(
                clip,
                spokenDuration: ClipDurationFormatter.accessibilityString(from: clip.duration),
                date: clip.recordedAt.formatted(date: .abbreviated, time: .omitted),
                isInPhotos: isInPhotos))
            .accessibilityAddTraits(selection == true ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(selection == nil ? Text("Opens the clip") : Text("Marks the clip for deleting"))
            .accessibilityIdentifier("library-clip-tile")
            .task(id: clip.exportAssetID) { isInPhotos = LibraryClipMedia.asset(for: clip) != nil }
    }
}
