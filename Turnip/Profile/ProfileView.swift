import SwiftUI

/// A screen pushed from the Profile page (`docs/PROFILE_DESIGN.md` §5.2).
enum ProfileRoute: Hashable {
    /// The clips saved without a name, in the order "Needs a name" opened them.
    case needsAName([UUID])
    /// One trick's clips, under the gallery's filter.
    case trick(key: String, filter: TrickGallery.Filter)
    case clip(UUID)
}

/// The Profile tab (`docs/PROFILE_DESIGN.md` §5): the root pager's third page, computed on the
/// device from the clip library and never sent anywhere. One scrolling page: "Needs a name" while
/// any saved clip has no name, the achievements each trick has earned, and the gallery grouped by
/// trick. Its pushed screens own the full screen, so `RootTabView` hides the floating bar and stops
/// the pager while `path` holds one.
struct ProfileView: View {
    @ObservedObject var library: ClipLibrary
    @ObservedObject var vocabulary: VocabularyStore
    @Binding var path: [ProfileRoute]

    @State private var filter: TrickGallery.Filter = .mine

    var body: some View {
        NavigationStack(path: $path) {
            page
                .navigationTitle("Profile")
                // Inline: inside the root pager a large title loses the bar's leading margin.
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: ProfileRoute.self, destination: destination(for:))
        }
        // A newer vocabulary can merge two names' counts without the library changing.
        .onAppear { library.refreshEarned() }
        .onChange(of: vocabulary.current) { _ in library.refreshEarned() }
    }

    private var progress: [TrickProgress] {
        let counts = Achievements.counts(
            of: library.clips, vocabulary: vocabulary.current, calendar: .autoupdatingCurrent)
        return Achievements.progress(counts: counts, earned: library.earned, vocabulary: vocabulary.current)
    }

    private var groups: [TrickGallery.Group] {
        TrickGallery.groups(of: library.clips, filter: filter, vocabulary: vocabulary.current)
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                privacyNote
                if library.clips.isEmpty && library.earned.isEmpty {
                    emptyState
                } else {
                    needsAName
                    achievements
                    gallery
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            // The floating tab bar overlays this page rather than reserving space for itself.
            .padding(.bottom, FloatingTabBarMetrics.clearance)
        }
        .accessibilityIdentifier("profile")
    }

    private var privacyNote: some View {
        Label("Your Profile stays on this iPhone.", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("profile-privacy-note")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.gymnastics")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No clips yet")
                .font(.headline)
            Text("Save clips from a video and name their tricks. Each trick's levels, reps and clips gather here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile-empty")
    }

    // MARK: - Needs a name

    @ViewBuilder
    private var needsAName: some View {
        let unnamed = library.unnamedClips
        if !unnamed.isEmpty {
            NavigationLink(value: ProfileRoute.needsAName(unnamed.map(\.id))) {
                HStack(spacing: 12) {
                    Image(systemName: "tag")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs a name")
                            .font(.headline)
                        Text(ProfileAccessibility.clipCount(unnamed.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProfileAccessibility.needsANameLabel(count: unnamed.count))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("needs-a-name")
        }
    }

    // MARK: - Achievements

    private var achievements: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Achievements")
            let progress = progress
            if progress.isEmpty {
                Text("Name a clip of yourself to start that trick's levels.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    ForEach(progress) { trick in
                        AchievementCard(progress: trick, kind: .level)
                        if trick.repMilestone != nil {
                            AchievementCard(progress: trick, kind: .reps)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Gallery")
            Picker("Whose clips", selection: $filter) {
                Text("Me").tag(TrickGallery.Filter.mine)
                Text("Everyone").tag(TrickGallery.Filter.everyone)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("gallery-filter")
            let groups = groups
            if groups.isEmpty {
                Text(filter == .mine ? "No named clips of yours yet." : "No named clips yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        galleryRow(group)
                        if group.id != groups.last?.id { Divider().padding(.leading, 68) }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func galleryRow(_ group: TrickGallery.Group) -> some View {
        NavigationLink(value: ProfileRoute.trick(key: group.trick.key, filter: filter)) {
            HStack(spacing: 12) {
                if let newest = group.clips.first {
                    LibraryClipThumbnail(clip: newest)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.trick.title)
                        .font(.body.weight(.semibold))
                    Text(ProfileAccessibility.clipCount(group.clips.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProfileAccessibility.galleryRowLabel(trick: group.trick, count: group.clips.count))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("gallery-trick-\(group.trick.identifier)")
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: ProfileRoute) -> some View {
        switch route {
        case .needsAName(let ids):
            LibraryNamingView(clipIDs: ids, library: library, vocabulary: vocabulary, close: pop)
        case .trick(let key, let filter):
            TrickClipsView(trickKey: key, filter: filter, library: library, vocabulary: vocabulary)
        case .clip(let id):
            LibraryClipView(clipID: id, library: library, vocabulary: vocabulary, close: pop)
        }
    }

    private func pop() {
        if !path.isEmpty { path.removeLast() }
    }
}

/// One achievement card (`docs/PROFILE_DESIGN.md` §6): a trick's level, or the highest rep
/// milestone it has earned, with a bar toward the next step that reads from today's count.
struct AchievementCard: View {
    let progress: TrickProgress
    let kind: AchievementKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.trick.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.title3.weight(.bold))
            ProgressView(value: fraction)
                .tint(kind == .level ? .accentColor : .orange)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier("achievement-\(progress.trick.identifier)-\(kind.rawValue)")
    }

    private var headline: String {
        switch kind {
        case .level: return String(localized: "Level \(progress.level)")
        case .reps: return String(localized: "\(progress.repMilestone ?? 0) reps")
        }
    }

    private var label: String {
        switch kind {
        case .level: return ProfileAccessibility.levelCardLabel(progress)
        case .reps: return ProfileAccessibility.repsCardLabel(progress, milestone: progress.repMilestone ?? 0)
        }
    }

    private var value: String {
        switch kind {
        case .level: return ProfileAccessibility.levelCardValue(progress)
        case .reps: return ProfileAccessibility.repsCardValue(progress)
        }
    }

    /// Today's count against the next step; a full bar at the top of the ladder.
    private var fraction: Double {
        switch kind {
        case .level:
            guard let next = progress.nextLevel else { return 1 }
            return min(Double(progress.sessions) / Double(next.sessions), 1)
        case .reps:
            guard let next = progress.nextRepMilestone else { return 1 }
            return min(Double(progress.reps) / Double(next), 1)
        }
    }
}
