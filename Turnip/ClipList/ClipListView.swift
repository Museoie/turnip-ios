import AVFoundation
import AVKit
import SwiftUI

/// The triage screen (`docs/UIUX.md` § "Clip List (triage)"): one card per
/// detected trick window — thumbnail, an inline trim timeline with draggable
/// start/end handles, duration, and the keep/discard toggle — plus the "Export N
/// clips" action and a "Select All" / "Deselect All" toolbar button.
///
/// The processing screen pushes this with the pipeline's output. Tapping a card's
/// thumbnail plays the clip full-screen; a per-card Edit button navigates to the clip
/// editor (which still owns crop); the export action goes to export confirmation. The
/// back chevron pops to Home rather than to the processing screen, Photos-app style —
/// centered inline title on the same line as the chevron.
/// This view deliberately
/// declares no `NavigationStack` of its own — it lives on the flow's shared stack.
struct ClipListView: View {
    @StateObject private var viewModel: ClipListViewModel
    @State private var showingExport = false
    @State private var editorDestination: ClipListDestination?
    let popToRoot: () -> Void

    init(
        items: [ClipListItem],
        asset: AVAsset,
        loader: ClipThumbnailLoader = ClipThumbnailLoader(),
        popToRoot: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: ClipListViewModel(
            items: items, asset: asset, loader: loader))
        self.popToRoot = popToRoot
    }

    /// The export-confirmation screen's per-clip export, wired to the real
    /// pipeline step 7 (`ClipExporter`): trims the source video to the window,
    /// crops to its rect, and writes an `.mp4` into the screen's scratch
    /// directory. Failures surface as `ExportConfirmationError.exportFailed`
    /// so the screen's per-clip callout names the step; cancellation
    /// propagates untouched so the screen stops the run instead of failing
    /// the clip.
    private static let exportOneClip: ExportOneClip = { window, cropRect, asset, directory, progress in
        do {
            let exported = try await ClipExporter().export(
                ClipSpec(window: window, cropRect: cropRect),
                from: asset,
                to: directory,
                progress: progress)
            return exported.fileURL
        } catch {
            if error is CancellationError { throw error }
            throw ExportConfirmationError.exportFailed(reason: error.localizedDescription)
        }
    }

    /// The export-confirmation screen's Photos save, wired to `ClipPhotosSaver`
    /// (add-only authorization). Failures surface as
    /// `ExportConfirmationError.photosSaveFailed` so the per-clip callout names
    /// the step.
    private static let saveOneClipToPhotos: SaveOneClipToPhotos = { url in
        do {
            try await ClipPhotosSaver().saveVideo(at: url)
        } catch {
            throw ExportConfirmationError.photosSaveFailed(reason: error.localizedDescription)
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 16
            ) {
                ForEach(viewModel.items) { item in
                    ClipCardView(
                        item: item,
                        viewModel: viewModel,
                        onEdit: { editorDestination = .editor(item.id) })
                }
            }
            .padding()
        }
        .navigationTitle("Clips")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // The default back chevron would step back to the processing screen;
            // the flow's "back" is Home, so this screen draws its own chevron —
            // Photos-style, chevron only, no text label.
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    popToRoot()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Back to Home")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(viewModel.allKept ? "Deselect All" : "Select All") {
                    if viewModel.allKept {
                        viewModel.deselectAll()
                    } else {
                        viewModel.selectAll()
                    }
                }
            }
        }
        .navigationDestination(item: $editorDestination) { destination in
            switch destination {
            case .editor(let id):
                // The editor's commit writes back into the list by id so
                // trim/crop edits commit on back-navigation (docs/UIUX.md
                // § "Clip Detail / Editor").
                if let item = viewModel.binding(for: id) {
                    ClipEditorView(
                        source: viewModel.editorSource(for: item.wrappedValue),
                        onCommit: { result in
                            viewModel.applyEditorResult(result, to: id)
                        })
                }
            }
        }
        .navigationDestination(isPresented: $showingExport) {
            ExportConfirmationView(
                items: viewModel.exportConfirmationItems,
                asset: viewModel.sourceAsset,
                exportClip: Self.exportOneClip,
                saveToPhotos: Self.saveOneClipToPhotos,
                popToRoot: popToRoot)
        }
        .safeAreaInset(edge: .bottom) {
            Button(viewModel.exportTitle) { showingExport = true }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canExport)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.thinMaterial)
        }
    }
}

/// The clip list's navigation exit: the card's Edit button goes to the editor. The
/// destination carries the item's id rather than the item itself so the editor can bind
/// back into the view model's list — edits commit to the triage list on back-navigation
/// instead of dying with a value copy.
/// (Tapping a card's thumbnail plays the clip full-screen instead of navigating
/// anywhere; the editor stays reachable through the Edit button.)
/// The export action uses `isPresented` instead, so the destination reads the kept clips at
/// navigation time rather than at body-evaluation time.
private enum ClipListDestination: Hashable {
    case editor(UUID)
}

/// One triage card: the clip's thumbnail (tap to play the clip full-screen), its inline
/// trim timeline, its duration, and the keep/discard toggle plus the Edit button.
///
/// The toggle and the Edit button sit *outside* the play button as a `ZStack` overlay so
/// tapping either never starts playback — the issue calls the toggle a quick action that
/// must not require opening detail, and the editor stays one tap away without hijacking
/// the card. The trim timeline sits below the thumbnail, also outside the play button,
/// so handle drags never fight the tap gesture.
private struct ClipCardView: View {
    let item: ClipListItem
    @ObservedObject var viewModel: ClipListViewModel
    let onEdit: () -> Void
    @State private var thumbnail: CGImage?
    @State private var placeholderRatio: CGFloat?
    @State private var duration: TimeInterval?
    @State private var isPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button {
                    isPlaying = true
                } label: {
                    thumbnailView
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play clip")

                HStack(spacing: 0) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel("Edit clip")

                    Button(
                        action: { viewModel.toggleKeep(item) },
                        label: {
                            Image(systemName: item.isKept ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                        }
                    )
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel(item.isKept ? "Discard clip" : "Keep clip")
                }
            }
            .opacity(item.isKept ? 1 : 0.45)

            if let duration {
                ClipWindowTrimView(window: windowBinding, duration: duration)
            }

            Text(item.durationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fullScreenCover(isPresented: $isPlaying) {
            ClipPlayerView(window: playbackWindow, asset: viewModel.sourceAsset)
        }
        .task {
            // Fetch the displayed-space placeholder ratio alongside the thumbnail. The
            // ratio is cached per asset, and the thumbnail shares one in-flight decode
            // per card — a `.task` re-fire joins the decode already running (or reads
            // the cached image) instead of seeking the same frame a second time. The
            // duration is cached per asset the same way, for the trim timeline.
            async let ratio = viewModel.placeholderAspectRatio(for: item)
            async let image = viewModel.thumbnail(for: item)
            async let assetDuration = viewModel.assetDuration()
            placeholderRatio = await ratio
            thumbnail = await image
            duration = await assetDuration
        }
    }

    /// The window as of now, for playback and the trim binding: trims land in the view
    /// model, and both read the current value rather than the card's snapshot.
    private var playbackWindow: TrickWindow {
        viewModel.items.first(where: { $0.id == item.id })?.window ?? item.window
    }

    /// A write-through binding to the item's window for the inline trim timeline.
    private var windowBinding: Binding<TrickWindow> {
        Binding(
            get: { playbackWindow },
            set: { viewModel.setWindow($0, for: item.id) }
        )
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = thumbnail {
            // The generator hands back the displayed (upright) frame, so `.up` is exact —
            // no UIKit bridge needed.
            Image(decorative: image, scale: 1.0, orientation: .up)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(placeholderRatio ?? encodedSpaceRatio, contentMode: .fit)
                .overlay { ProgressView() }
        }
    }

    /// The crop rect's own ratio (encoded space): the best guess before the track
    /// geometry loads. The view model replaces it with the displayed-space ratio —
    /// the space the decoded thumbnail renders in — as soon as the track's
    /// `preferredTransform` is known, so cards don't reflow when thumbnails land.
    private var encodedSpaceRatio: CGFloat {
        let width = CGFloat(item.cropRect.width), height = CGFloat(item.cropRect.height)
        guard width > 0, height > 0 else { return 9.0 / 16.0 }
        return width / height
    }
}

/// Full-screen playback for one clip, presented from the card's thumbnail tap
/// (`docs/UIUX.md` § "Clip List (triage)").
///
/// Seeks to the window's start on appear, plays, and pauses at the window's end via a
/// boundary-time observer; the close button dismisses. The player is torn down on
/// disappear so no audio keeps running behind the list.
private struct ClipPlayerView: View {
    let window: TrickWindow
    let asset: AVAsset
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var endObserver: Any?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding()
            }
            .accessibilityLabel("Close player")
        }
        .task {
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            player.seek(
                to: CMTime(seconds: window.startTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero)
            endObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(
                    time: CMTime(seconds: window.endTime, preferredTimescale: 600))],
                queue: .main
            ) { [weak player] in
                player?.pause()
            }
            player.play()
        }
        .onDisappear {
            if let endObserver, let player {
                player.removeTimeObserver(endObserver)
            }
            player?.pause()
            self.endObserver = nil
        }
    }
}

#Preview {
    NavigationStack {
        ClipListView(
            items: [
                ClipListItem(
                    window: TrickWindow(startTime: 2, endTime: 5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)
                ),
                ClipListItem(
                    window: TrickWindow(startTime: 9, endTime: 11.5),
                    cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
                    isKept: false
                )
            ],
            // AVAsset is abstract and throws at runtime; AVURLAsset is the concrete
            // subclass. The URL resolves to nothing — the preview shows the
            // placeholder tiles, which is the honest fallback.
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        )
    }
}
