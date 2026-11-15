import SwiftUI

/// Every achievement the Profile counts, as tiles (`docs/PROFILE_DESIGN.md` §6.7): what the Profile's
/// achievements carousel opens with "Show More". The user's totals lead; then a tile per trick, its
/// level and reps each toward its next step and the days it was first and last practiced, which
/// opens that trick's clips; then what was earned most recently, and how each ladder climbs.
struct AchievementsView: View {
    @ObservedObject var library: ClipLibrary
    @ObservedObject var vocabulary: VocabularyStore
    let close: () -> Void

    /// iPhone Duo's vertical bar, which the back button goes down instead.
    @Environment(\.verticalBar) private var verticalBar

    private static let recentLimit = 5
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

    private var progress: [TrickProgress] {
        let counts = Achievements.counts(
            of: library.clips, vocabulary: vocabulary.current, calendar: .autoupdatingCurrent)
        return Achievements.progress(counts: counts, earned: library.earned, vocabulary: vocabulary.current)
    }

    var body: some View {
        let progress = progress
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if progress.isEmpty {
                    Text("Name a clip of yourself to start that trick's levels.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    totals(progress)
                    tricks(progress)
                    recentlyEarned
                }
                ladders
            }
            .padding()
        }
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(verticalBar != nil)
        .verticalBarSlotControls {
            ScrimIconButton(systemImage: "chevron.backward", accessibilityLabel: "Back to Profile", action: close)
                .accessibilityIdentifier("achievements-back")
        }
        .accessibilityIdentifier("achievements-screen")
    }

    // MARK: - Totals

    private func totals(_ progress: [TrickProgress]) -> some View {
        let summary = Achievements.summary(
            of: library.clips, progress: progress, vocabulary: vocabulary.current, calendar: .autoupdatingCurrent)
        return LazyVGrid(columns: columns, spacing: 12) {
            AchievementStat(value: summary.achievements, label: "Achievements", systemImage: "rosette")
            AchievementStat(value: summary.tricks, label: "Tricks", systemImage: "figure.gymnastics")
            AchievementStat(value: summary.sessions, label: "Days practiced", systemImage: "calendar")
            AchievementStat(value: summary.clips, label: "Clips of you", systemImage: "film.stack")
        }
        .accessibilityIdentifier("achievements-totals")
    }

    // MARK: - Tricks

    private func tricks(_ progress: [TrickProgress]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("By trick")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(progress) { trick in
                    if trick.reps > 0 {
                        NavigationLink(value: ProfileRoute.trick(key: trick.trick.key, filter: .mine)) {
                            AchievementTile(progress: trick)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the trick's clips")
                    } else {
                        // Earned, but no clip of it is left to open.
                        AchievementTile(progress: trick)
                    }
                }
            }
        }
    }

    // MARK: - Recently earned

    @ViewBuilder
    private var recentlyEarned: some View {
        let records = Achievements.recentlyEarned(library.earned, limit: Self.recentLimit)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Recently earned")
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.offset) { offset, record in
                        earnedRow(record)
                        if offset < records.count - 1 { Divider().padding(.leading, 52) }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityIdentifier("achievements-recent")
        }
    }

    private func earnedRow(_ record: EarnedAchievement) -> some View {
        let title = TrickNaming.tricks(for: record.trick, vocabulary: vocabulary.current).first?.title
            ?? Trick(key: record.trick, name: record.trick).title
        return HStack(spacing: 12) {
            Image(systemName: record.kind == .level ? "star.fill" : "flame.fill")
                .foregroundStyle(record.kind == .level ? Color.accentColor : Color.orange)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ProfileAccessibility.earnedTitle(record, trickTitle: title))
                    .font(.body.weight(.semibold))
                Text(record.earnedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Ladders

    private var ladders: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("How levels and reps work")
            VStack(alignment: .leading, spacing: 8) {
                Text(ProfileAccessibility.levelLadder)
                Text(ProfileAccessibility.repLadder)
                Text(ProfileAccessibility.ladderNote)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier("achievements-ladders")
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// One of the achievements page's totals: a figure over what it counts.
private struct AchievementStat: View {
    let value: Int
    let label: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(value, format: .number)
                .font(.title2.weight(.bold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// One trick's tile on the achievements page: its level and reps, each with a bar toward the next
/// step that reads from today's count (as `AchievementCard`'s do), and its first and last day.
private struct AchievementTile: View {
    let progress: TrickProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.trick.title)
                .font(.headline)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Level \(progress.level)")
                    .font(.title3.weight(.bold))
                ProgressView(value: levelFraction)
                    .tint(.accentColor)
                Text(ProfileAccessibility.levelCardValue(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(ProfileAccessibility.repsHeadline(progress))
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: repsFraction)
                    .tint(.orange)
                Text(ProfileAccessibility.repsCardValue(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let days = ProfileAccessibility.practicedDays(progress) {
                Text(days)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProfileAccessibility.levelCardLabel(progress))
        .accessibilityValue(ProfileAccessibility.tileValue(progress))
        .accessibilityIdentifier("achievement-tile-\(progress.trick.identifier)")
    }

    /// Today's sessions against the next level; a full bar at the top of the ladder.
    private var levelFraction: Double {
        guard let next = progress.nextLevel else { return 1 }
        return min(Double(progress.sessions) / Double(next.sessions), 1)
    }

    /// Today's reps against the next milestone; a full bar at the top of the ladder.
    private var repsFraction: Double {
        guard let next = progress.nextRepMilestone else { return 1 }
        return min(Double(progress.reps) / Double(next), 1)
    }
}
