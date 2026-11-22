import AVFoundation
import SwiftUI

/// The Clip view (`docs/PROFILE_DESIGN.md` §5.2): plays a saved clip full screen the way Home plays
/// a video — the picture fit to the screen over black, Home's scrub bar over the bottom — and swipes
/// sideways to the clip before or after it in its trick's grid. A swipe up, or a tap on the names
/// over the bar, brings up the clip's names and who is in it for editing, with its date. The trash
/// deletes the clip from the library, asking whether its video leaves Photos too, and the next clip
/// takes its place. Its window and framing are what export made of them and can't change here.
///
/// Pages through the grid's clips as they were when it opened, so a clip renamed here stays on
/// screen rather than leaving the pager under the user's finger. The pager owns every horizontal
/// drag, as Needs a name's does — the system's swipe back from the edge stands down with the back
/// button — so the back chevron is the only way back.
struct LibraryClipView: View {
    /// The clip the view opened on.
    let clipID: UUID
    /// The clips a swipe sideways reaches, in the grid's order.
    let among: [UUID]
    @ObservedObject var library: ClipLibrary
    @ObservedObject var vocabulary: VocabularyStore
    /// Pops back once the last clip is deleted.
    let close: () -> Void

    /// The clip on screen, once a swipe or a delete has moved off `clipID`.
    @State private var currentID: UUID?
    @State private var dragOffset: CGFloat = 0
    /// Which way the drag in progress went first, read for the rest of it: sideways pages, up
    /// brings up the names.
    @State private var dragAxis: Axis?
    /// Set by the scrub bar while a drag on its track is in progress, so that drag only scrubs.
    @State private var isScrubbing = false
    /// Latches `isScrubbing` for the rest of the drag that saw it, as Processing's swipe does: the bar
    /// reports its scrub's end as the finger lifts, which can reach the pager before its own
    /// `onEnded` runs.
    @State private var dragWasScrub = false
    /// `@GestureState`, so a drag the system cancels — which never reaches `onEnded` — still lets go.
    @GestureState private var isDragTouchActive = false
    /// From a page turn until its slide has settled. A quick flick that lifts on the names button
    /// reaches the button after the swipe has turned the page, and mustn't bring the names up too.
    @State private var isTurningPage = false
    @State private var isShowingNames = false
    @State private var draft = ""
    @State private var removalPrompt: LibraryClipRemovalPrompt?
    @State private var deleteFailure: String?
    /// iPhone Duo's vertical bar, which the top controls go down instead.
    @Environment(\.verticalBar) private var verticalBar

    private static let slideDuration: TimeInterval = 0.3
    private static let slide: Animation = .easeInOut(duration: slideDuration)

    /// The clips a swipe sideways reaches, any deleted meanwhile dropped. Read on every frame of a
    /// drag, so the library is indexed once here rather than scanned for each clip.
    private var clips: [LibraryClip] {
        let byID = Dictionary(library.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (among.contains(clipID) ? among : [clipID]).compactMap { byID[$0] }
    }

    private var shownID: UUID { currentID ?? clipID }

    /// For a control's action; a render reads the clip from `clips`.
    private var currentClip: LibraryClip? { library.clip(shownID) }

    var body: some View {
        let clips = self.clips
        let index = clips.firstIndex { $0.id == shownID }
        Group {
            if let index {
                pager(clips, index: index)
            } else {
                Text("This clip is no longer in your Profile.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        // Over the pager rather than in it, so they stay put while the pages slide under them.
        .overlay(alignment: .top) {
            if verticalBar == nil {
                topControls(hasClip: index != nil)
            }
        }
        // No bar at all, as on Processing: the video runs to the top of the screen, and a drag that
        // starts there reaches the pager. Its back button stays hidden too, which also stands down
        // the system's swipe back, so a swipe from the leading edge pages like any other.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .verticalBarSlotControls(refreshingOn: index != nil) { hasClip in
            backButton
            if hasClip { deleteButton }
        }
        .sheet(isPresented: $isShowingNames, onDismiss: commitDraft) {
            LibraryClipNamesSheet(
                clipID: shownID, library: library, vocabulary: vocabulary, draft: $draft,
                commitDraft: commitDraft)
        }
        .libraryClipRemovalDialog($removalPrompt, remove: delete)
        .errorAlert("Couldn't delete the video", message: $deleteFailure)
        .onChange(of: isScrubbing) { scrubbing in
            // The track's report can arrive after the pager has already moved the page: the scrub
            // takes the drag over, and the page goes back to rest under it.
            guard scrubbing, dragAxis != nil, !dragWasScrub else { return }
            dragWasScrub = true
            springBack()
        }
        .onChange(of: isDragTouchActive) { isActive in
            // A drag whose `onEnded` ran has already let go; one the system cancelled hasn't.
            guard !isActive else { return }
            dragAxis = nil
            dragWasScrub = false
            springBack()
        }
        .onDisappear(perform: commitDraft)
        .accessibilityIdentifier("clip-view")
    }

    // MARK: - Controls

    /// Where a bar's items would sit, the back chevron leading and the trash across from it.
    private func topControls(hasClip: Bool) -> some View {
        HStack {
            backButton
            Spacer(minLength: 0)
            if hasClip {
                deleteButton
            }
        }
        .screenHeaderItemPlacement()
    }

    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back") {
            commitDraft()
            close()
        }
        .accessibilityIdentifier("clip-view-back")
    }

    private var deleteButton: some View {
        ScrimIconButton(systemImage: "trash", accessibilityLabel: "Delete Clip") {
            commitDraft()
            removalPrompt = currentClip.map { LibraryClipRemovalPrompt(clips: [$0]) }
        }
        .accessibilityIdentifier("clip-view-delete")
    }

    // MARK: - Pager

    private func pager(_ clips: [LibraryClip], index: Int) -> some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(clips.enumerated()), id: \.element.id) { offset, clip in
                    if abs(offset - index) <= 1 {
                        page(for: clip, isCurrent: offset == index, in: clips, at: index)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .offset(x: CGFloat(offset - index) * proxy.size.width + dragOffset)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            // Beside the scrub bar's own drag on its track rather than over it, as on Processing:
            // `isScrubbing` tells this one to let that drag be.
            .simultaneousGesture(pagingGesture(clips, index: index))
        }
        // The names sheet's keyboard is the sheet's to make room for; the pages under it stay put.
        .ignoresSafeArea(.keyboard)
    }

    /// The pages beside the current one wait off screen to slide in; nothing on them is the user's
    /// to reach until they land.
    private func page(for clip: LibraryClip, isCurrent: Bool, in clips: [LibraryClip], at index: Int) -> some View {
        var goToPrevious: (() -> Void)?
        var goToNext: (() -> Void)?
        if isCurrent, index > 0 {
            goToPrevious = { go(to: index - 1, in: clips) }
        }
        if isCurrent, index < clips.count - 1 {
            goToNext = { go(to: index + 1, in: clips) }
        }
        return LibraryClipStage(
            clip: clip, isCurrent: isCurrent, showNames: showNames, onScrubbingChanged: { isScrubbing = $0 },
            goToPrevious: goToPrevious, goToNext: goToNext)
        .allowsHitTesting(isCurrent)
        .accessibilityHidden(!isCurrent)
    }

    /// A drag sideways carries the pages with it and, let go, turns to the clip before (right) or
    /// after (left) when it went far or fast enough, by `BrowseSwipe`'s measure, or springs back;
    /// at either end of the grid it gives only a little. A drag up as far or as fast brings up the
    /// names. Built with the clips it pages through, `index` the current one's place among them.
    private func pagingGesture(_ clips: [LibraryClip], index: Int) -> some Gesture {
        let hasPrevious = index > 0
        let hasNext = index < clips.count - 1
        return DragGesture(minimumDistance: 20)
            .updating($isDragTouchActive) { _, state, _ in state = true }
            .onChanged { value in
                if isScrubbing, !dragWasScrub {
                    dragWasScrub = true
                    springBack()
                }
                guard !dragWasScrub else { return }
                if dragAxis == nil {
                    let translation = value.translation
                    dragAxis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                dragOffset = BrowseSwipe.pageOffset(
                    translation: value.translation.width, hasPrevious: hasPrevious, hasNext: hasNext)
            }
            .onEnded { value in
                defer {
                    dragAxis = nil
                    dragWasScrub = false
                }
                guard !dragWasScrub else { return }
                if dragAxis == .horizontal {
                    turnPage(after: value, in: clips, from: index)
                } else if dragAxis == .vertical, Self.isSwipeUp(value) {
                    showNames()
                }
            }
    }

    /// Where a sideways drag that has let go leaves the pages: on the clip it turned to, or back
    /// where they were.
    private func turnPage(after value: DragGesture.Value, in clips: [LibraryClip], from index: Int) {
        let direction = BrowseSwipe.commit(
            translation: value.translation.width,
            predictedTranslation: value.predictedEndTranslation.width,
            hasPrevious: index > 0, hasNext: index < clips.count - 1)
        switch direction {
        case .next: go(to: index + 1, in: clips)
        case .previous: go(to: index - 1, in: clips)
        case nil: springBack()
        }
    }

    /// Up by as much as a sideways drag needs to turn the page, or flicked up as far: the same
    /// distances Processing's swipe down reads.
    private static func isSwipeUp(_ value: DragGesture.Value) -> Bool {
        -value.translation.height >= BrowseSwipe.commitDistance
            || -value.predictedEndTranslation.height >= BrowseSwipe.flickDistance
    }

    /// The one way to another clip, for the swipe and VoiceOver's actions alike: commits what is
    /// typed to the clip being left, then slides to the clip at `target` in `clips`.
    private func go(to target: Int, in clips: [LibraryClip]) {
        guard clips.indices.contains(target) else { return }
        commitDraft()
        isTurningPage = true
        withAnimation(Self.slide) {
            currentID = clips[target].id
            dragOffset = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.slideDuration * 1_000_000_000))
            isTurningPage = false
        }
    }

    private func springBack() {
        guard dragOffset != 0 else { return }
        withAnimation(Self.slide) { dragOffset = 0 }
    }

    private func showNames() {
        guard !isTurningPage, currentClip != nil else { return }
        isShowingNames = true
    }

    // MARK: - Naming and deleting

    /// A name typed and left without pressing return still counts as given.
    private func commitDraft() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        library.addName(draft, origin: .typed, to: shownID)
        draft = ""
    }

    /// Removes the clip, after its video when that goes too. A video Photos didn't delete — the
    /// user declined its confirmation — keeps the clip as well, and the screen with it. Otherwise the
    /// clips after it close up, so the next one slides into its place, or the one before when it was
    /// the last; with none left the screen goes back.
    private func delete(_ removed: [LibraryClip], alsoFromPhotos: Bool) {
        let position = clips.firstIndex { $0.id == shownID } ?? 0
        Task {
            do {
                guard try await LibraryClipRemoval(library: library).remove(removed, alsoFromPhotos: alsoFromPhotos)
                else { return }
            } catch {
                deleteFailure = error.localizedDescription
                return
            }
            draft = ""
            let remaining = clips
            guard !remaining.isEmpty else {
                close()
                return
            }
            withAnimation(Self.slide) {
                currentID = remaining[min(position, remaining.count - 1)].id
                dragOffset = 0
            }
        }
    }
}

/// One clip's page on the Clip view: the clip fit to the screen over black, its still until the
/// first frame is ready, and along the bottom its names over Home's scrub bar (`VideoScrubBar`). The
/// clip plays with its sound and starts over at its end, as Home's player does, though never on its
/// own under Reduce Motion or with video autoplay off. A page beside the current one builds its
/// player paused, and shows the bar's resting look in the bar's place, so the page that slides in
/// is the page that lands.
private struct LibraryClipStage: View {
    let clip: LibraryClip
    let isCurrent: Bool
    let showNames: () -> Void
    let onScrubbingChanged: (Bool) -> Void
    /// VoiceOver's way to the clips a swipe reaches; nil at either end, and on a page beside the
    /// current one.
    let goToPrevious: (() -> Void)?
    let goToNext: (() -> Void)?

    @StateObject private var playback = LibraryClipPlayback(loops: false)
    @State private var isReady = false

    var body: some View {
        ZStack {
            picture
            LibraryClipLoadStatus(phase: playback.phase, retry: retry)
        }
        // A safe-area inset rather than an overlay, as on Processing: the bar gets the full width
        // to lay out in, while the picture, which ignores the safe area, runs on under it.
        .safeAreaInset(edge: .bottom) {
            controls
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .task(id: clip.exportAssetID) {
            isReady = false
            await playback.load(clip, autoplay: false)
        }
        .onChange(of: isCurrent) { current in
            if current { playback.playIfAllowed() } else { playback.pause() }
        }
        // Played once loaded rather than as the load starts, so a page that became the current one
        // while its video was still coming plays too.
        .onChange(of: playback.phase) { phase in
            guard phase == .ready, isCurrent else { return }
            playback.playIfAllowed()
        }
        .onDisappear { playback.teardown() }
    }

    private var picture: some View {
        ZStack {
            Color.black
            if !isReady {
                LibraryClipThumbnail(clip: clip, contentMode: .fit)
            }
            if let player = playback.player {
                BareVideoPlayerView(player: player, onReadyForDisplay: { isReady = true })
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Clip video"))
        .accessibilityActions {
            if let goToPrevious { Button("Previous clip", action: goToPrevious) }
            if let goToNext { Button("Next clip", action: goToNext) }
        }
    }

    /// The real bar only on the current page, built as the page becomes it: `VideoScrubBar` reads
    /// whether the player is playing once, when it appears, and the page has started or stopped its
    /// player by then.
    private var controls: some View {
        VStack(spacing: 12) {
            namesButton
            if isCurrent, let player = playback.player {
                VideoScrubBar(player: player, onScrubbingChanged: onScrubbingChanged)
            } else {
                VideoScrubBar.Placeholder()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The clip's names, with the chevron that says a swipe up brings them up; a tap does too.
    private var namesButton: some View {
        Button(action: showNames) {
            HStack(spacing: 6) {
                Text(Self.title(of: clip))
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.4)))
            .touchTarget(insetBy: 4, axes: .vertical)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edits the clip's names")
        .accessibilityIdentifier("clip-view-names")
    }

    /// "Cork + Hook"; a clip left without a name asks for one.
    static func title(of clip: LibraryClip) -> String {
        guard !clip.names.isEmpty else { return String(localized: "Add a name") }
        return clip.names.map(\.name).joined(separator: " + ")
    }

    private func retry() {
        Task { await playback.load(clip, autoplay: false) }
    }
}

/// The names a swipe up on the Clip view brings up: the clip's date and length, then the same naming
/// controls as Name Clips, which write to the library as they're used. Swiped down, or tapped
/// outside, it goes, keeping a name typed and left without pressing return.
private struct LibraryClipNamesSheet: View {
    let clipID: UUID
    @ObservedObject var library: ClipLibrary
    @ObservedObject var vocabulary: VocabularyStore
    @Binding var draft: String
    let commitDraft: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Group {
            if let clip = library.clip(clipID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(details(of: clip))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("clip-view-date")
                        ClipNamingFields(
                            names: clip.names, isMe: clip.isMe,
                            suggested: PersonalLayer.shared.suggestions(
                                forSaved: clip, used: library.namesUsed(alongside: clip)
                            ).withRecent(library.recentNames),
                            vocabulary: vocabulary.current, draft: $draft, isFieldFocused: $isFieldFocused,
                            isEnabled: true, commitDraft: commitDraft, actions: actions(for: clip.id))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("clip-view-names-sheet")
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
}
