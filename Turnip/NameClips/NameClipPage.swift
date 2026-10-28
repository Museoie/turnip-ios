import SwiftUI

/// The size of Name Clips' card, worked out once from the screen and never from the page's
/// content, so a swipe, a name added, a "did you mean" line or the keyboard can't move it.
enum NameClipsLayout {
    static let horizontalInset: CGFloat = 16
    /// Room kept under the card for the naming controls before the card gives up height: the
    /// field, a row of suggestions, and who's in it. More controls than that scroll rather than
    /// shrink the card.
    static let controlsReserve: CGFloat = 240
    static let minimumSide: CGFloat = 220

    /// The card's side for a page `size` points large, measured without the keyboard: the
    /// width less its insets, unless that leaves less than `controlsReserve` below it.
    static func cardSide(for size: CGSize) -> CGFloat {
        let byWidth = size.width - 2 * horizontalInset
        let byHeight = size.height - controlsReserve
        return max(min(byWidth, byHeight), min(minimumSide, byWidth))
    }
}

/// One clip's page on Name Clips: its card on top at the screen's fixed size, and under it the
/// trick-name field, the names given as removable chips, suggestions, and who is in the clip.
/// The page scrolls, so the keyboard moves the controls into view instead of squeezing the
/// card — but not while a swipe is paging, which holds it still.
struct NameClipPage: View {
    let item: ClipListItem
    let cardSide: CGFloat
    @ObservedObject var viewModel: ClipListViewModel
    let vocabulary: TrickVocabulary
    @Binding var draft: String
    var isFieldFocused: FocusState<Bool>.Binding
    let isCurrent: Bool
    let isCardPlaying: Bool
    let isCardHidden: Bool
    /// True while a horizontal swipe is paging between clips: the page's own scroll stops, so
    /// the swipe slides it sideways and never up or down too.
    let isPaging: Bool
    let commitDraft: () -> Void
    let openEditor: (CGRect, CGImage?, TimeInterval?) -> Void
    /// The card's VoiceOver actions for the swipe (`NameClipCard.onPrevious`, `onNext`).
    let goToPrevious: (() -> Void)?
    let goToNext: (() -> Void)?

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    NameClipCard(
                        item: item, side: cardSide, viewModel: viewModel, isPlaying: isCardPlaying,
                        isHidden: isCardHidden, onOpen: openEditor, onPrevious: goToPrevious, onNext: goToNext)
                    VStack(alignment: .leading, spacing: 12) {
                        ClipNamingFields(
                            names: item.names, isMe: item.isMe, usedNames: viewModel.namesUsedOnVideo,
                            vocabulary: vocabulary, draft: $draft, isFieldFocused: isFieldFocused,
                            isEnabled: isCurrent, commitDraft: commitDraft, actions: namingActions)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, NameClipsLayout.horizontalInset)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDisabled(isPaging)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isFieldFocused.wrappedValue) { focused in
                guard focused, isCurrent else { return }
                // After the keyboard's own animation has moved the page's bottom edge up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        scroller.scrollTo(ClipNamingFields.suggestionsID, anchor: .bottom)
                    }
                }
            }
            // A name added while typing grows the chips above the field; the suggestions stay in view.
            .onChange(of: item.names.count) { _ in
                guard isFieldFocused.wrappedValue, isCurrent else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    scroller.scrollTo(ClipNamingFields.suggestionsID, anchor: .bottom)
                }
            }
        }
    }

    private var namingActions: ClipNamingActions {
        ClipNamingActions(
            add: { viewModel.addName($0, origin: $1, to: item.id) },
            remove: { viewModel.removeName($0, from: item.id) },
            replace: { viewModel.replaceName($0, with: $1, in: item.id) },
            setIsMe: { viewModel.setIsMe($0, for: item.id) })
    }
}
