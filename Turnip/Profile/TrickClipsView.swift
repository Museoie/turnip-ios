import SwiftUI

/// One trick's clips (`docs/PROFILE_DESIGN.md` §7): a grid of the gallery's tiles, newest first,
/// under the filter the gallery had when it opened. A tile opens the Clip view.
struct TrickClipsView: View {
    let trickKey: String
    let filter: TrickGallery.Filter
    @ObservedObject var library: ClipLibrary
    @ObservedObject var vocabulary: VocabularyStore

    private static let spacing: CGFloat = 2
    private let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)

    /// Read from the library each time, so a clip renamed or deleted on the Clip view leaves this
    /// grid when it comes back.
    private var group: TrickGallery.Group? {
        TrickGallery.groups(of: library.clips, filter: filter, vocabulary: vocabulary.current)
            .first { $0.trick.key == trickKey }
    }

    var body: some View {
        Group {
            if let group {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Self.spacing) {
                        ForEach(group.clips) { clip in
                            NavigationLink(value: ProfileRoute.clip(clip.id)) {
                                LibraryClipTile(clip: clip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(ProfileAccessibility.galleryRowLabel(trick: group.trick, count: group.clips.count))
            } else {
                Text("No clips of this trick.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(group?.trick.title ?? Trick(key: trickKey, name: trickKey).title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("trick-clips")
    }
}

/// A gallery tile: the clip's still, its length over a scrim, and a mark on a clip of someone else.
struct LibraryClipTile: View {
    let clip: LibraryClip

    @State private var isInPhotos = true

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { LibraryClipThumbnail(clip: clip) }
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
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProfileAccessibility.tileLabel(
                clip,
                spokenDuration: ClipDurationFormatter.accessibilityString(from: clip.duration),
                date: clip.recordedAt.formatted(date: .abbreviated, time: .omitted),
                isInPhotos: isInPhotos))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the clip")
            .accessibilityIdentifier("library-clip-tile")
            .task(id: clip.exportAssetID) { isInPhotos = LibraryClipMedia.asset(for: clip) != nil }
    }
}
