import SwiftUI

/// Removes saved clips from the clip library (`docs/PROFILE_DESIGN.md` §5.2), deleting their
/// videos from Photos first when the user chose that too: the Clip view's delete, Needs a name's
/// remove, and a trick's clips removed together. Photos asks its own confirmation before it
/// deletes, once for all of them; a decline throws, and every clip stays, with its video, since
/// nothing was deleted.
@MainActor
struct LibraryClipRemoval {
    let library: ClipLibrary
    /// Deletes the videos with these `PHAsset.localIdentifier`s in one Photos change. Injected so
    /// tests needn't reach Photos.
    var deleteVideos: (_ assetIdentifiers: [String]) async throws -> Void = { identifiers in
        try await PhotoAssetDeleter().delete(assetIdentifiers: identifiers)
    }

    func remove(_ clips: [LibraryClip], alsoFromPhotos: Bool) async throws {
        guard !clips.isEmpty else { return }
        if alsoFromPhotos {
            try await deleteVideos(clips.map(\.exportAssetID))
        }
        library.delete(Set(clips.map(\.id)))
    }
}

extension View {
    /// The confirmation every removal of saved clips asks first (`LibraryClipRemoval`): from the
    /// Profile alone, or with their videos from Photos too, which is offered while any of them is
    /// still in Photos. `remove` gets whether the videos go too.
    func libraryClipRemovalDialog(
        isPresented: Binding<Bool>, clips: [LibraryClip], remove: @escaping (_ alsoFromPhotos: Bool) -> Void
    ) -> some View {
        confirmationDialog(
            ProfileAccessibility.removalTitle(count: clips.count),
            isPresented: isPresented, titleVisibility: .visible
        ) {
            Button("Remove from Profile", role: .destructive) { remove(false) }
            if LibraryClipMedia.anyInPhotos(clips) {
                if clips.count == 1 {
                    Button("Remove and Delete Video from Photos", role: .destructive) { remove(true) }
                } else {
                    Button("Remove and Delete Videos from Photos", role: .destructive) { remove(true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if clips.count == 1 {
                Text("What this clip earned stays earned.")
            } else {
                Text("What these clips earned stays earned.")
            }
        }
    }
}
