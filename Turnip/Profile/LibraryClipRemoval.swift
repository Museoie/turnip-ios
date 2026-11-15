import Photos
import SwiftUI

/// Removes saved clips from the clip library (`docs/PROFILE_DESIGN.md` §5.2), deleting their
/// videos from Photos first when the user chose that too: the Clip view's delete, Needs a name's
/// remove, and a trick's clips removed together. Photos asks its own confirmation before it
/// deletes, once for all of them; declining it is the user changing their mind, so every clip
/// stays, with its video, and nothing is reported.
@MainActor
struct LibraryClipRemoval {
    let library: ClipLibrary
    /// Deletes the videos with these `PHAsset.localIdentifier`s in one Photos change. Injected so
    /// tests needn't reach Photos.
    var deleteVideos: (_ assetIdentifiers: [String]) async throws -> Void = { identifiers in
        try await PhotoAssetDeleter().delete(assetIdentifiers: identifiers)
    }

    /// Whether the clips left the library: `false` when the user declined Photos' confirmation.
    /// Any other failure to delete the videos throws, and keeps every clip too.
    @discardableResult
    func remove(_ clips: [LibraryClip], alsoFromPhotos: Bool) async throws -> Bool {
        guard !clips.isEmpty else { return false }
        if alsoFromPhotos {
            do {
                try await deleteVideos(clips.map(\.exportAssetID))
            } catch let error as PHPhotosError where error.code == .userCancelled {
                return false
            }
        }
        library.delete(Set(clips.map(\.id)))
        return true
    }
}

/// The clips a removal asks about, taken when the user asks to remove them, and whether any of
/// their videos is still in Photos to offer deleting: read once, there, rather than each time the
/// screen under the confirmation draws.
struct LibraryClipRemovalPrompt {
    let clips: [LibraryClip]
    let offersPhotos: Bool

    init(clips: [LibraryClip]) {
        self.clips = clips
        offersPhotos = LibraryClipMedia.anyInPhotos(clips)
    }
}

extension View {
    /// The confirmation every removal of saved clips asks first (`LibraryClipRemoval`), while
    /// `prompt` is set: from the Profile alone, or with their videos from Photos too, offered while
    /// any of them is still there. `remove` gets the prompt's clips and whether the videos go too.
    func libraryClipRemovalDialog(
        _ prompt: Binding<LibraryClipRemovalPrompt?>,
        remove: @escaping (_ clips: [LibraryClip], _ alsoFromPhotos: Bool) -> Void
    ) -> some View {
        let isPresented = Binding(
            get: { prompt.wrappedValue != nil },
            set: { if !$0 { prompt.wrappedValue = nil } })
        return confirmationDialog(
            ProfileAccessibility.removalTitle(count: prompt.wrappedValue?.clips.count ?? 0),
            isPresented: isPresented, titleVisibility: .visible, presenting: prompt.wrappedValue
        ) { shown in
            Button("Remove from Profile", role: .destructive) { remove(shown.clips, false) }
            if shown.offersPhotos {
                if shown.clips.count == 1 {
                    Button("Remove and Delete Video from Photos", role: .destructive) { remove(shown.clips, true) }
                } else {
                    Button("Remove and Delete Videos from Photos", role: .destructive) { remove(shown.clips, true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { shown in
            if shown.clips.count == 1 {
                Text("What this clip earned stays earned.")
            } else {
                Text("What these clips earned stays earned.")
            }
        }
    }
}
