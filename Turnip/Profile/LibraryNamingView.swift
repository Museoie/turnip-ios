import AVFoundation
import SwiftUI

/// "Needs a name" (`docs/PROFILE_DESIGN.md` §4.1, `docs/UIUX.md` § "Name Clips"): Name Clips'
/// naming for clips already saved without names. One clip at a time on a looping card, the same
/// naming controls under it, and "Skip" / "Next" paging with the same slide a swipe plays. The
/// clips are already in Photos, so there is no save: names go to the clip library as they are
/// given, and the last clip's button is "Done".
///
/// Pages through the clips that needed a name when it opened, so a clip named here stays on screen
/// rather than leaving the pager under the user's finger. The pager owns every horizontal drag;
/// the back chevron is the only way back.
struct LibraryNamingView: View {
    let clipIDs: [UUID]
    @ObservedObject var library: ClipLibrary
    @ObservedObject var vocabulary: VocabularyStore
    let close: () -> Void

    @State private var index = 0
    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool
    @State private var screenSize: CGSize = .zero

    private static let slide: Animation = .easeInOut(duration: 0.3)

    /// A clip deleted elsewhere meanwhile drops out.
    private var clips: [LibraryClip] { clipIDs.compactMap(library.clip) }
    private var isLast: Bool { index >= clips.count - 1 }
    private var cardSide: CGFloat { NameClipsLayout.cardSide(for: screenSize) }

    var body: some View {
        Group {
            if clips.isEmpty {
                Text("Every clip has a name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pager
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { screenSize = proxy.size }
                    .onChange(of: proxy.size) { size in
                        if size.width != screenSize.width || screenSize == .zero { screenSize = size }
                    }
            }
            .ignoresSafeArea(.keyboard)
        }
        .navigationTitle(clips.isEmpty ? "" : String(localized: "\(index + 1) of \(clips.count)"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if !clips.isEmpty {
                PrimaryActionBar(primaryTitle) {
                    if isLast {
                        commitDraft()
                        close()
                    } else {
                        go(to: index + 1)
                    }
                }
                .accessibilityIdentifier("needs-a-name-primary")
            }
        }
        .accessibilityIdentifier("needs-a-name-screen")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            // The chevron is glass already; the bar's own glass behind it would double it.
            ToolbarItem(placement: .navigationBarLeading) { backButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigationBarLeading) { backButton }
        }
    }

    private var backButton: some View {
        ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to Profile") {
            commitDraft()
            close()
        }
        .accessibilityIdentifier("needs-a-name-back")
    }

    private var primaryTitle: String {
        if isLast { return String(localized: "Done") }
        let hasName = clips.indices.contains(index) && !(clips[index].names.isEmpty && draft.isBlank)
        return hasName ? String(localized: "Next") : String(localized: "Skip")
    }

    // MARK: - Pager

    private var pager: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(clips.enumerated()), id: \.element.id) { offset, clip in
                    if abs(offset - index) <= 1 {
                        page(for: clip, isCurrent: offset == index)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .offset(x: CGFloat(offset - index) * proxy.size.width + dragOffset)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(pagingGesture)
        }
        .clipped()
    }

    private func page(for clip: LibraryClip, isCurrent: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                LibraryClipPlayer(clip: clip, videoGravity: .resizeAspectFill, isActive: isCurrent)
                    .frame(width: cardSide, height: cardSide)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Clip \(index + 1) of \(clips.count)"))
                ClipNamingFields(
                    names: clip.names, isMe: clip.isMe, usedNames: library.namesUsed(alongside: clip),
                    vocabulary: vocabulary.current, draft: isCurrent ? $draft : .constant(""),
                    isFieldFocused: $isFieldFocused, isEnabled: isCurrent, commitDraft: commitDraft,
                    actions: actions(for: clip.id))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, NameClipsLayout.horizontalInset)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var pagingGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                dragOffset = BrowseSwipe.pageOffset(
                    translation: value.translation.width, hasPrevious: index > 0, hasNext: !isLast)
            }
            .onEnded { value in
                defer { dragAxis = nil }
                guard dragAxis == .horizontal else { return }
                let direction = BrowseSwipe.commit(
                    translation: value.translation.width,
                    predictedTranslation: value.predictedEndTranslation.width,
                    hasPrevious: index > 0, hasNext: !isLast)
                switch direction {
                case .next: go(to: index + 1)
                case .previous: go(to: index - 1)
                case nil: withAnimation(Self.slide) { dragOffset = 0 }
                }
            }
    }

    /// The one entry point the swipe and the button share: commits what is typed to the clip being
    /// left, then slides to `target`.
    private func go(to target: Int) {
        guard clips.indices.contains(target) else { return }
        commitDraft()
        withAnimation(Self.slide) {
            index = target
            dragOffset = 0
        }
    }

    // MARK: - Naming

    private func actions(for id: UUID) -> ClipNamingActions {
        ClipNamingActions(
            add: { library.addName($0, origin: $1, to: id) },
            remove: { library.removeName($0, from: id) },
            replace: { library.replaceName($0, with: $1, in: id) },
            setIsMe: { setIsMe($0, for: id) })
    }

    /// As on Name Clips, a choice on a video's first clip here carries to its later clips here that
    /// still read the way the first one did.
    private func setIsMe(_ isMe: Bool, for id: UUID) {
        guard let clip = library.clip(id) else { return }
        let sameVideo = clips.filter { $0.sourceAssetID == clip.sourceAssetID }
        if sameVideo.first?.id == id {
            for other in sameVideo.dropFirst() where other.isMe == clip.isMe {
                library.setIsMe(isMe, for: other.id)
            }
        }
        library.setIsMe(isMe, for: id)
    }

    /// A name typed and left without pressing return still counts as given.
    private func commitDraft() {
        guard clips.indices.contains(index), !draft.isBlank else { return }
        library.addName(draft, origin: .typed, to: clips[index].id)
        draft = ""
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
