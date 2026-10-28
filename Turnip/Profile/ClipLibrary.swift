import Foundation
import os
import Photos

/// One video that produced at least one saved clip (`docs/PROFILE_DESIGN.md` §2.1).
struct LibrarySource: Codable, Hashable, Sendable {
    /// The original's `PHAsset.localIdentifier`. Never leaves the device.
    let assetID: String
    /// When the original was recorded (`PHAsset.creationDate`); `nil` when Photos had no date.
    var recordedAt: Date?
    var duration: TimeInterval
}

/// One clip saved to Photos (`docs/PROFILE_DESIGN.md` §2.1).
struct LibraryClip: Codable, Hashable, Identifiable, Sendable {
    /// The clip's `clip_id`, minted when the clip was created on Name Clips: the ID a contribution
    /// sends.
    let id: UUID
    let sourceAssetID: String
    /// The window, in source seconds.
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// The saved clip's `PHAsset.localIdentifier`. Never leaves the device.
    var exportAssetID: String
    var names: [ClipName]
    var isMe: Bool
    var isAutoDetected: Bool
    /// When the trick happened: the source's recording date plus the clip's offset into it, or the
    /// save's date when Photos had no recording date. Sessions and the gallery's order read it.
    var recordedAt: Date
    let savedAt: Date

    var duration: TimeInterval { endTime - startTime }
}

/// What one Name Clips save hands the library: the video and each of its clips now in Photos.
struct LibrarySave: Sendable {
    struct Clip: Sendable {
        let id: UUID
        let window: TrickWindow
        let exportAssetID: String
        let names: [ClipName]
        let isMe: Bool
        let isAutoDetected: Bool
    }

    let sourceAssetID: String
    let sourceDuration: TimeInterval
    let clips: [Clip]
}

/// The on-device clip library (`docs/PROFILE_DESIGN.md` §2): every clip Name Clips saved, its
/// names and whether it shows the user, and the achievements earned from them. The Profile is
/// computed from it on the device; nothing in it is sent anywhere.
///
/// Kept as one JSON file in `Application Support/`, which is in the user's device backups and is
/// never evicted, rewritten whole and atomically on every change. The file carries a schema
/// version: a file this build can't read — corrupt, or written by a newer build — is moved aside
/// under a dated name rather than overwritten, and the library starts empty. A failed write is
/// logged and leaves the change in memory for this run; the next change writes the whole library
/// again.
@MainActor
final class ClipLibrary: ObservableObject {
    static let shared = ClipLibrary(fileURL: ClipLibrary.defaultFileURL, vocabulary: { VocabularyStore.shared.current })

    static let schemaVersion = 1

    @Published private(set) var clips: [LibraryClip] = []
    @Published private(set) var sources: [LibrarySource] = []
    @Published private(set) var earned: [EarnedAchievement] = []

    private let fileURL: URL?
    private let vocabulary: @MainActor () -> TrickVocabulary
    private let calendar: Calendar
    private let now: () -> Date
    /// Speaks an achievement earned by a name given on the Profile's own screens. One earned by a
    /// Name Clips save is spoken by that save's own announcement instead.
    private let announce: AccessibilityAnnouncing
    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "ClipLibrary")

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var sources: [LibrarySource]
        var clips: [LibraryClip]
        var earned: [EarnedAchievement]
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    init(
        fileURL: URL?,
        vocabulary: @escaping @MainActor () -> TrickVocabulary,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init,
        announce: @escaping AccessibilityAnnouncing = postAccessibilityAnnouncement
    ) {
        self.fileURL = fileURL
        self.vocabulary = vocabulary
        self.calendar = calendar
        self.now = now
        self.announce = announce
        load()
    }

    nonisolated static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipLibrary", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    // MARK: - Reading

    func clip(_ id: UUID) -> LibraryClip? {
        clips.first { $0.id == id }
    }

    /// Saved clips with no name yet, for "Needs a name": the most recent video first, each video's
    /// clips in the order they happen.
    var unnamedClips: [LibraryClip] {
        clips.filter(\.names.isEmpty).sorted { lhs, rhs in
            let lhsSource = lhs.recordedAt.addingTimeInterval(-lhs.startTime)
            let rhsSource = rhs.recordedAt.addingTimeInterval(-rhs.startTime)
            if lhs.sourceAssetID != rhs.sourceAssetID { return lhsSource > rhsSource }
            return lhs.startTime < rhs.startTime
        }
    }

    /// The names given to clips of `clip`'s video, each once, in the order the clips happen: the
    /// first suggestions when naming it, since a session is mostly repeats of a few tricks.
    func namesUsed(alongside clip: LibraryClip) -> [String] {
        var seen = Set<String>()
        return clips
            .filter { $0.sourceAssetID == clip.sourceAssetID }
            .sorted { $0.startTime < $1.startTime }
            .flatMap(\.names)
            .map(\.name)
            .filter { seen.insert(TrickVocabulary.normalized($0)).inserted }
    }

    // MARK: - Writing

    /// Records a save: the video, and each clip with the asset Photos gave it and the names it had.
    /// A clip already in the library is updated in place, keeping the date it was first saved —
    /// a retry after a partial failure, or a clip edited and saved again. Returns the achievements
    /// the save earned, for the save's own announcement to speak.
    @discardableResult
    func record(_ save: LibrarySave, sourceRecordedAt: Date?) -> [EarnedAchievement] {
        guard !save.clips.isEmpty else { return [] }
        let savedAt = now()
        let source: LibrarySource
        if let index = sources.firstIndex(where: { $0.assetID == save.sourceAssetID }) {
            sources[index].recordedAt = sources[index].recordedAt ?? sourceRecordedAt
            sources[index].duration = save.sourceDuration
            source = sources[index]
        } else {
            source = LibrarySource(
                assetID: save.sourceAssetID, recordedAt: sourceRecordedAt, duration: save.sourceDuration)
            sources.append(source)
        }
        for saved in save.clips {
            let existing = clip(saved.id)
            let clip = LibraryClip(
                id: saved.id,
                sourceAssetID: save.sourceAssetID,
                startTime: saved.window.startTime,
                endTime: saved.window.endTime,
                exportAssetID: saved.exportAssetID,
                names: saved.names,
                isMe: saved.isMe,
                isAutoDetected: saved.isAutoDetected,
                recordedAt: source.recordedAt?.addingTimeInterval(saved.window.startTime) ?? existing?.recordedAt
                    ?? savedAt,
                savedAt: existing?.savedAt ?? savedAt)
            if let index = clips.firstIndex(where: { $0.id == saved.id }) {
                clips[index] = clip
            } else {
                clips.append(clip)
            }
        }
        let newlyEarned = recordEarned()
        persist()
        return newlyEarned
    }

    /// Adds a trick name to a saved clip, by the same rules as naming on Name Clips.
    func addName(_ name: String, origin: LabelOrigin, to id: UUID) {
        update(id) { $0.names.addName(name, origin: origin) }
    }

    func removeName(_ name: ClipName, from id: UUID) {
        update(id) { clip in
            let count = clip.names.count
            clip.names.removeAll { $0 == name }
            return clip.names.count != count
        }
    }

    /// "Did you mean": the vocabulary's spelling in place of a typed name.
    func replaceName(_ name: ClipName, with canonical: String, in id: UUID) {
        update(id) { $0.names.replaceName(name, with: canonical) }
    }

    func setIsMe(_ isMe: Bool, for id: UUID) {
        update(id) { clip in
            guard clip.isMe != isMe else { return false }
            clip.isMe = isMe
            return true
        }
    }

    /// Removes a clip from the library; its video in Photos is the caller's to delete or keep. A
    /// video with no clip left goes too. What the clip earned stays earned.
    func delete(_ id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let sourceAssetID = clips.remove(at: index).sourceAssetID
        if !clips.contains(where: { $0.sourceAssetID == sourceAssetID }) {
            sources.removeAll { $0.assetID == sourceAssetID }
        }
        persist()
    }

    /// Records and announces what the library earns under today's vocabulary: a newer one can merge
    /// two names' counts without the library changing, so the Profile calls this as it appears and
    /// when the vocabulary changes.
    func refreshEarned() {
        let newlyEarned = recordEarned()
        guard !newlyEarned.isEmpty else { return }
        persist()
        announce(ProfileAccessibility.earnedAnnouncement(newlyEarned))
    }

    /// Writes an earned record for each level and milestone the library now reaches that none
    /// records yet.
    private func recordEarned() -> [EarnedAchievement] {
        let counts = Achievements.counts(of: clips, vocabulary: vocabulary(), calendar: calendar)
        let newlyEarned = Achievements.newlyEarned(
            counts: counts, earned: earned, vocabulary: vocabulary(), at: now())
        guard !newlyEarned.isEmpty else { return [] }
        earned += newlyEarned
        return newlyEarned
    }

    /// Applies `change` to one clip; `change` returns whether it changed anything. A change that
    /// earns something is announced here, since the screens that name saved clips have no save of
    /// their own to announce it with.
    private func update(_ id: UUID, _ change: (inout LibraryClip) -> Bool) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        var clip = clips[index]
        guard change(&clip) else { return }
        clips[index] = clip
        let newlyEarned = recordEarned()
        persist()
        if !newlyEarned.isEmpty {
            announce(ProfileAccessibility.earnedAnnouncement(newlyEarned))
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let header = try JSONDecoder().decode(SchemaHeader.self, from: data)
            guard header.schemaVersion == Self.schemaVersion else {
                Self.logger.error("Library schema \(header.schemaVersion) is not \(Self.schemaVersion)")
                setAside(fileURL)
                return
            }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            sources = snapshot.sources
            clips = snapshot.clips
            earned = snapshot.earned
        } catch {
            Self.logger.error("Library unreadable: \(error.localizedDescription, privacy: .public)")
            setAside(fileURL)
        }
    }

    /// Moves an unreadable library file out of the way, so the next write can't destroy what a
    /// newer build, or a later fix, could still read.
    private func setAside(_ fileURL: URL) {
        let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        let destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("library-unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
        } catch {
            Self.logger.error("Couldn't set the library aside: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = Snapshot(schemaVersion: Self.schemaVersion, sources: sources, clips: clips, earned: earned)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Library write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The production library writer for `ClipListViewModel`: reads the video's recording date from
/// Photos while the video is still there — a save that deletes the original does so afterwards.
@MainActor
func recordInClipLibrary(_ save: LibrarySave) -> [EarnedAchievement] {
    let recordedAt = PHAsset.fetchAssets(withLocalIdentifiers: [save.sourceAssetID], options: nil)
        .firstObject?.creationDate
    return ClipLibrary.shared.record(save, sourceRecordedAt: recordedAt)
}
