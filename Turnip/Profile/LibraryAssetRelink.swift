import Foundation
import Photos

/// A video in this device's Photos library, as the legacy relink compares it with a saved record.
struct LibraryAssetCandidate: Equatable, Sendable {
    let localID: String
    let duration: TimeInterval
}

/// What the library asks PhotoKit to keep its records pointing at the right videos
/// (`docs/PROFILE_DESIGN.md` §3.2). Injected so tests can stand in for Photos.
///
/// A `PHAsset.localIdentifier` is minted per device: a library restored onto a new iPhone from a
/// backup holds identifiers that name nothing in that iPhone's Photos, even with iCloud Photos
/// bringing every video along. `PHCloudIdentifier` names the same asset on every device signed in
/// to the same iCloud Photos library, so the library keeps one beside each local identifier and
/// maps it back to this device's local identifier when the local one no longer resolves.
struct LibraryAssetLookup: Sendable {
    /// Whether the app can read the whole library. Relinking a record whose video wasn't found
    /// waits for it: under limited access a video outside the selection looks just as gone, and
    /// the legacy match could pick the wrong one among the few the selection holds.
    var canReadWholeLibrary: @Sendable () -> Bool
    /// Which of these local identifiers name an asset in this device's Photos library.
    var existing: @Sendable (_ localIDs: [String]) -> Set<String>
    /// Each local identifier's iCloud identifier, for those Photos has one for. A video not yet
    /// uploaded to iCloud Photos, or a device without it, has none yet; the next pass asks again.
    var cloudIDs: @Sendable (_ localIDs: [String]) -> [String: String]
    /// Each iCloud identifier's local identifier on this device, for those Photos can find. A video
    /// iCloud Photos hasn't brought down to a new device yet isn't found until it has.
    var localIDs: @Sendable (_ cloudIDs: [String]) -> [String: String]
    /// The library's videos created within `range`, for records saved before the library kept
    /// iCloud identifiers.
    var videos: @Sendable (_ createdIn: ClosedRange<Date>) -> [LibraryAssetCandidate]
}

extension LibraryAssetLookup {
    /// The production lookup, reading this device's Photos library under the app's existing grant.
    static let photos = LibraryAssetLookup(
        canReadWholeLibrary: {
            PhotoLibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite)) == .authorized
        },
        existing: { localIDs in
            guard !localIDs.isEmpty else { return [] }
            var found = Set<String>()
            PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil)
                .enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
            return found
        },
        cloudIDs: { localIDs in
            guard !localIDs.isEmpty else { return [:] }
            return PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIDs)
                .compactMapValues { try? $0.get().stringValue }
        },
        localIDs: { cloudIDs in
            guard !cloudIDs.isEmpty else { return [:] }
            let mappings = PHPhotoLibrary.shared()
                .localIdentifierMappings(for: cloudIDs.map { PHCloudIdentifier(stringValue: $0) })
            var found: [String: String] = [:]
            for (cloudID, mapping) in mappings {
                if let localID = try? mapping.get() { found[cloudID.stringValue] = localID }
            }
            return found
        },
        videos: { range in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@",
                range.lowerBound as NSDate, range.upperBound as NSDate)
            var found: [LibraryAssetCandidate] = []
            PHAsset.fetchAssets(with: .video, options: options).enumerateObjects { asset, _, _ in
                found.append(LibraryAssetCandidate(localID: asset.localIdentifier, duration: asset.duration))
            }
            return found
        })
}

/// What one relink pass changes in the library: worked out off the main actor from a copy of its
/// records, then applied only where a record still holds what the pass read.
struct LibraryAssetRelink: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        let from: String
        let to: String
    }

    /// Per clip, its video's local identifier on this device, where the one it held names nothing.
    var exports: [UUID: Change] = [:]
    /// Per clip, the iCloud identifier of its video, keyed to the local identifier it was read for.
    var exportCloudIDs: [UUID: Change] = [:]
    /// Per source, keyed by the local identifier the library holds: its identifier on this device.
    var sources: [String: String] = [:]
    /// Per source, keyed by the local identifier the library holds: its video's iCloud identifier.
    var sourceCloudIDs: [String: String] = [:]

    var isEmpty: Bool {
        exports.isEmpty && exportCloudIDs.isEmpty && sources.isEmpty && sourceCloudIDs.isEmpty
    }

    /// Works out the pass. In order:
    /// 1. A record whose local identifier names nothing here, and which holds an iCloud identifier,
    ///    takes the local identifier Photos maps that iCloud identifier to.
    /// 2. A record saved before the library kept iCloud identifiers takes the one video, among
    ///    those no other record holds, that matches it (`LegacyMatcher`).
    /// 3. Every record that now names a video here and holds no iCloud identifier gets one.
    static func make(
        clips: [LibraryClip], sources: [LibrarySource], lookup: LibraryAssetLookup
    ) -> LibraryAssetRelink {
        var relink = LibraryAssetRelink()
        let held = Array(Set(clips.map(\.exportAssetID) + sources.map(\.assetID)))
        guard !held.isEmpty else { return relink }
        let present = lookup.existing(held)
        if lookup.canReadWholeLibrary() {
            let missingClips = clips.filter { !present.contains($0.exportAssetID) }
            let missingSources = sources.filter { !present.contains($0.assetID) }
            relink.relinkByCloudID(missingClips, missingSources, lookup: lookup)
            var matcher = LegacyMatcher(
                lookup: lookup,
                claimed: present.union(relink.exports.values.map(\.to)).union(relink.sources.values),
                sourceDurations: Dictionary(
                    sources.map { ($0.assetID, $0.duration) }, uniquingKeysWith: { first, _ in first }))
            relink.relinkLegacy(missingClips, missingSources, matcher: &matcher)
        }
        relink.addCloudIDs(clips, sources, present: present, lookup: lookup)
        return relink
    }

    private mutating func relinkByCloudID(
        _ clips: [LibraryClip], _ sources: [LibrarySource], lookup: LibraryAssetLookup
    ) {
        let cloudIDs = Set(clips.compactMap(\.exportCloudID) + sources.compactMap(\.cloudID))
        guard !cloudIDs.isEmpty else { return }
        let found = lookup.localIDs(Array(cloudIDs))
        for clip in clips {
            guard let localID = clip.exportCloudID.flatMap({ found[$0] }), localID != clip.exportAssetID
            else { continue }
            exports[clip.id] = Change(from: clip.exportAssetID, to: localID)
        }
        for source in sources {
            guard let localID = source.cloudID.flatMap({ found[$0] }), localID != source.assetID else { continue }
            self.sources[source.assetID] = localID
        }
    }

    /// Matches every record with no iCloud identifier that the first step left unlinked. A match
    /// another record takes can leave a record that had two with one, so this repeats while it
    /// relinks anything.
    private mutating func relinkLegacy(
        _ clips: [LibraryClip], _ sources: [LibrarySource], matcher: inout LegacyMatcher
    ) {
        var relinkedAny = true
        while relinkedAny {
            relinkedAny = false
            for source in sources where source.cloudID == nil && self.sources[source.assetID] == nil {
                guard let localID = matcher.match(source) else { continue }
                self.sources[source.assetID] = localID
                relinkedAny = true
            }
            for clip in clips where clip.exportCloudID == nil && exports[clip.id] == nil {
                guard let localID = matcher.match(clip) else { continue }
                exports[clip.id] = Change(from: clip.exportAssetID, to: localID)
                relinkedAny = true
            }
        }
    }

    private mutating func addCloudIDs(
        _ clips: [LibraryClip], _ sources: [LibrarySource], present: Set<String>, lookup: LibraryAssetLookup
    ) {
        func here(_ held: String, relinked: String?) -> String? {
            relinked ?? (present.contains(held) ? held : nil)
        }
        let clipsAsking = clips.filter { $0.exportCloudID == nil }.compactMap { clip -> (UUID, String)? in
            here(clip.exportAssetID, relinked: exports[clip.id]?.to).map { (clip.id, $0) }
        }
        let sourcesAsking = sources.filter { $0.cloudID == nil }.compactMap { source -> (String, String)? in
            here(source.assetID, relinked: self.sources[source.assetID]).map { (source.assetID, $0) }
        }
        let asked = Set(clipsAsking.map { $0.1 } + sourcesAsking.map { $0.1 })
        guard !asked.isEmpty else { return }
        let cloudIDs = lookup.cloudIDs(Array(asked))
        for (clipID, localID) in clipsAsking {
            if let cloudID = cloudIDs[localID] { exportCloudIDs[clipID] = Change(from: localID, to: cloudID) }
        }
        for (heldID, localID) in sourcesAsking {
            if let cloudID = cloudIDs[localID] { sourceCloudIDs[heldID] = cloudID }
        }
    }
}

/// Finds the video a record saved before the library kept iCloud identifiers names on this device:
/// the one video, among those no record holds, that matches it. A source matches by the creation
/// date and duration the library read from its video, which iCloud Photos keeps. A clip matches by
/// its window's duration and a creation date during its save: the exporter writes no date of its
/// own, so Photos dates the clip by when it was saved. Two or more matches leave the record alone,
/// since a clip shown with another clip's video is worse than one shown as missing.
struct LegacyMatcher {
    let lookup: LibraryAssetLookup
    /// Every video a record holds or has been relinked to.
    var claimed: Set<String>
    let sourceDurations: [String: TimeInterval]
    private var candidates: [String: [LibraryAssetCandidate]] = [:]

    init(lookup: LibraryAssetLookup, claimed: Set<String>, sourceDurations: [String: TimeInterval]) {
        self.lookup = lookup
        self.claimed = claimed
        self.sourceDurations = sourceDurations
    }

    /// How far a source's video's creation date may sit from the one the library read from it.
    static let sourceDateTolerance: TimeInterval = 1
    /// How far a source's video's duration may sit from the one the library read from it.
    static let sourceDurationTolerance: TimeInterval = 0.5
    /// An exported clip is created in Photos while its save runs, before the library records the
    /// save's date, and a save of many long clips can take minutes. A little after allows for a
    /// clock corrected meanwhile.
    static let exportLead: TimeInterval = 60 * 60
    static let exportLag: TimeInterval = 5 * 60
    /// How far an exported clip's duration may sit from its window's: frame and audio rounding.
    static let exportDurationTolerance: TimeInterval = 0.25

    mutating func match(_ source: LibrarySource) -> String? {
        guard let recordedAt = source.recordedAt else { return nil }
        let range = recordedAt.addingTimeInterval(-Self.sourceDateTolerance)
            ... recordedAt.addingTimeInterval(Self.sourceDateTolerance)
        return claimOnly(
            unclaimed("source:" + source.assetID, range)
                .filter { abs($0.duration - source.duration) <= Self.sourceDurationTolerance })
    }

    mutating func match(_ clip: LibraryClip) -> String? {
        let range = clip.savedAt.addingTimeInterval(-Self.exportLead)
            ... clip.savedAt.addingTimeInterval(Self.exportLag)
        let expected = exportedDuration(of: clip)
        return claimOnly(
            unclaimed("clip:" + clip.id.uuidString, range)
                .filter { abs($0.duration - expected) <= Self.exportDurationTolerance })
    }

    /// The duration the exporter gave a clip: its window, trimmed to its source.
    private func exportedDuration(of clip: LibraryClip) -> TimeInterval {
        let end = sourceDurations[clip.sourceAssetID].map { min(clip.endTime, $0) } ?? clip.endTime
        return max(0, end - max(0, clip.startTime))
    }

    /// The videos created within `range` no record holds, fetched once per record per pass.
    private mutating func unclaimed(_ key: String, _ range: ClosedRange<Date>) -> [LibraryAssetCandidate] {
        let fetched = candidates[key] ?? lookup.videos(range)
        candidates[key] = fetched
        return fetched.filter { !claimed.contains($0.localID) }
    }

    private mutating func claimOnly(_ matches: [LibraryAssetCandidate]) -> String? {
        guard matches.count == 1, let match = matches.first else { return nil }
        claimed.insert(match.localID)
        return match.localID
    }
}
