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
    /// Whether the app can read the whole library. The match by date and duration waits for it:
    /// under limited access a video outside the selection looks gone, and the match could pick the
    /// wrong one among the few the selection holds. The map by iCloud identifier is exact, so it
    /// runs under any access and finds what the selection holds.
    var canReadWholeLibrary: @Sendable () -> Bool
    /// Which of these local identifiers name an asset in this device's Photos library.
    var existing: @Sendable (_ localIDs: [String]) -> Set<String>
    /// Each local identifier's iCloud identifier, for those Photos has one for. A video not yet
    /// uploaded to iCloud Photos, or a device without it, has none yet; the next pass asks again.
    var cloudIDs: @Sendable (_ localIDs: [String]) -> [String: String]
    /// Each iCloud identifier's local identifier on this device, for those Photos can find. A video
    /// iCloud Photos hasn't brought down to a new device yet isn't found until it has.
    var localIDs: @Sendable (_ cloudIDs: [String]) -> [String: String]
    /// The library's videos created within `range`, for records with no iCloud identifier that
    /// were saved on another device.
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

/// This device, as the relink pass tells the device that saved a record from one the library was
/// restored onto (`DeviceMark`).
struct LibraryDevice: Equatable, Sendable {
    let mark: String
    /// Whether the records saved before the library stamped them were saved on this device, once a
    /// pass on this device has decided it; `nil` until then.
    var legacySavedHere: Bool?
}

/// What one relink pass changes in the library: worked out off the main actor from a copy of its
/// records, then applied only where a record still holds what the pass read.
struct LibraryAssetRelink: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        let before: String
        let after: String
    }

    /// Per clip, its video's local identifier on this device, where the one it held names nothing.
    var exports: [UUID: Change] = [:]
    /// Per clip, the iCloud identifier of its video, keyed to the local identifier it was read for.
    var exportCloudIDs: [UUID: Change] = [:]
    /// Per source, keyed by the local identifier the library holds: its identifier on this device.
    var sources: [String: String] = [:]
    /// Per source, keyed by the local identifier the library holds: its video's iCloud identifier.
    var sourceCloudIDs: [String: String] = [:]
    /// This pass's decision on whether the unstamped records were saved on this device, when the
    /// device had none yet.
    var legacySavedHere: Bool?

    var isEmpty: Bool {
        exports.isEmpty && exportCloudIDs.isEmpty && sources.isEmpty && sourceCloudIDs.isEmpty
            && legacySavedHere == nil
    }

    /// Works out the pass. In order:
    /// 1. A record whose local identifier names nothing here, and which holds an iCloud identifier,
    ///    takes the local identifier Photos maps that iCloud identifier to.
    /// 2. With full access, a record with no iCloud identifier that was saved on another device
    ///    takes the one video that fits it and no other such record (`LegacyMatcher`). A record
    ///    saved on this device whose video names nothing was deleted in Photos, and stays so.
    /// 3. Every record that now names a video here and holds no iCloud identifier gets one.
    static func make(
        clips: [LibraryClip], sources: [LibrarySource], device: LibraryDevice?, lookup: LibraryAssetLookup
    ) -> LibraryAssetRelink {
        var relink = LibraryAssetRelink()
        let held = Array(Set(clips.map(\.exportAssetID) + sources.map(\.assetID)))
        guard !held.isEmpty else { return relink }
        let present = lookup.existing(held)
        let missingClips = clips.filter { !present.contains($0.exportAssetID) }
        let missingSources = sources.filter { !present.contains($0.assetID) }
        relink.relinkByCloudID(missingClips, missingSources, lookup: lookup)
        if let device {
            let wholeLibrary = lookup.canReadWholeLibrary()
            let legacySavedHere = device.legacySavedHere
                ?? relink.decideLegacySavedHere(clips, sources, present: present, wholeLibrary: wholeLibrary)
            if device.legacySavedHere == nil { relink.legacySavedHere = legacySavedHere }
            if wholeLibrary {
                let matcher = LegacyMatcher(
                    lookup: lookup,
                    claimed: present.union(relink.exports.values.map(\.after)).union(relink.sources.values),
                    sourceDurations: Dictionary(
                        sources.map { ($0.assetID, $0.duration) }, uniquingKeysWith: { first, _ in first }))
                relink.relinkSavedElsewhere(
                    missingClips, missingSources, device: device, legacySavedHere: legacySavedHere, matcher: matcher)
            }
        }
        relink.addCloudIDs(clips, sources, present: present, lookup: lookup)
        return relink
    }

    /// Whether the records saved before the library stamped them were saved on this device; `nil`
    /// when there are none, or when this pass can't tell yet.
    /// - One of them relinked by iCloud identifier in this pass held a local identifier this device
    ///   doesn't know, though Photos knows its video: it was saved elsewhere, under any access.
    /// - Otherwise, with full access, they were saved here if any of their videos is found by the
    ///   local identifier it holds, which no other device mints. Under limited access a video
    ///   outside the selection looks gone, so the decision waits.
    /// Decided before any relink of theirs makes their identifiers this device's own.
    private func decideLegacySavedHere(
        _ clips: [LibraryClip], _ sources: [LibrarySource], present: Set<String>, wholeLibrary: Bool
    ) -> Bool? {
        let unstampedClips = clips.filter { $0.savedOn == nil }
        let unstampedSources = sources.filter { $0.savedOn == nil }
        guard !unstampedClips.isEmpty || !unstampedSources.isEmpty else { return nil }
        if unstampedClips.contains(where: { exports[$0.id] != nil })
            || unstampedSources.contains(where: { self.sources[$0.assetID] != nil }) {
            return false
        }
        guard wholeLibrary else { return nil }
        let held = unstampedClips.map(\.exportAssetID) + unstampedSources.map(\.assetID)
        return !present.isDisjoint(with: held)
    }

    /// Step 2 of `make`, over the records with no iCloud identifier that were saved on another
    /// device.
    private mutating func relinkSavedElsewhere(
        _ clips: [LibraryClip], _ sources: [LibrarySource], device: LibraryDevice, legacySavedHere: Bool?,
        matcher: LegacyMatcher
    ) {
        func savedElsewhere(_ savedOn: String?) -> Bool {
            savedOn.map { $0 != device.mark } ?? (legacySavedHere == false)
        }
        relinkLegacy(
            clips.filter { $0.exportCloudID == nil && savedElsewhere($0.savedOn) },
            sources.filter { $0.cloudID == nil && savedElsewhere($0.savedOn) },
            matcher: matcher)
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
            exports[clip.id] = Change(before: clip.exportAssetID, after: localID)
        }
        for source in sources {
            guard let localID = source.cloudID.flatMap({ found[$0] }), localID != source.assetID else { continue }
            self.sources[source.assetID] = localID
        }
    }

    /// Pairs each record with the one video that fits it and no other record still unlinked, sources
    /// and clips alike: a record whose own video hasn't arrived yet still fits the videos it could
    /// be mistaken for, so it keeps another record from taking one. A record left with two fits, or
    /// with one another record shares, stays unlinked: a clip shown with another clip's video is
    /// worse than one shown as missing. Taking a video that fits no other record changes no other
    /// record's fits, so one round is all there is.
    private mutating func relinkLegacy(
        _ clips: [LibraryClip], _ sources: [LibrarySource], matcher: LegacyMatcher
    ) {
        var fits: [(LegacyMatcher.Record, [String])] = []
        for source in sources { fits.append((.source(source.assetID), matcher.fits(source))) }
        for clip in clips { fits.append((.clip(clip.id), matcher.fits(clip))) }
        let heldExports = Dictionary(clips.map { ($0.id, $0.exportAssetID) }, uniquingKeysWith: { first, _ in first })
        for (record, localID) in LegacyMatcher.uniquePairs(fits) {
            switch record {
            case .source(let assetID):
                self.sources[assetID] = localID
            case .clip(let id):
                guard let held = heldExports[id] else { continue }
                exports[id] = Change(before: held, after: localID)
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
            here(clip.exportAssetID, relinked: exports[clip.id]?.after).map { (clip.id, $0) }
        }
        let sourcesAsking = sources.filter { $0.cloudID == nil }.compactMap { source -> (String, String)? in
            here(source.assetID, relinked: self.sources[source.assetID]).map { (source.assetID, $0) }
        }
        let asked = Set(clipsAsking.map { $0.1 } + sourcesAsking.map { $0.1 })
        guard !asked.isEmpty else { return }
        let cloudIDs = lookup.cloudIDs(Array(asked))
        for (clipID, localID) in clipsAsking {
            if let cloudID = cloudIDs[localID] { exportCloudIDs[clipID] = Change(before: localID, after: cloudID) }
        }
        for (heldID, localID) in sourcesAsking {
            if let cloudID = cloudIDs[localID] { sourceCloudIDs[heldID] = cloudID }
        }
    }
}

/// The videos that could be a record's, for a record with no iCloud identifier saved on another
/// device. A source fits by the creation date and duration the library read from its video, which
/// iCloud Photos keeps. A clip fits by its window's duration and a creation date during its save:
/// the exporter writes no date of its own, so Photos dates the clip by when it was saved. A video
/// another record holds or has taken fits nothing.
struct LegacyMatcher {
    enum Record: Hashable {
        case source(String)
        case clip(UUID)
    }

    let lookup: LibraryAssetLookup
    /// Every video a record holds or has been relinked to by iCloud identifier.
    let claimed: Set<String>
    let sourceDurations: [String: TimeInterval]

    /// How far a source's video's creation date may sit from the one the library read from it.
    static let sourceDateTolerance: TimeInterval = 1
    /// How far a source's video's duration may sit from the one the library read from it.
    static let sourceDurationTolerance: TimeInterval = 0.5
    /// An exported clip is created in Photos while its save runs, before the library records the
    /// save's date, and a save of many long clips can take minutes. A little after allows for a
    /// clock corrected meanwhile.
    static let exportLead: TimeInterval = 60 * 60
    static let exportLag: TimeInterval = 5 * 60
    /// How far an exported clip's duration may sit from its window's: about a frame of video and
    /// one of audio. Wide enough that a clip's own video fits it, since a video that fits only a
    /// neighbor could be given to that neighbor; clips of one save closer than twice this can fit
    /// each other's videos, and are then left alone.
    static let exportDurationTolerance: TimeInterval = 0.1

    func fits(_ source: LibrarySource) -> [String] {
        guard let recordedAt = source.recordedAt else { return [] }
        let range = recordedAt.addingTimeInterval(-Self.sourceDateTolerance)
            ... recordedAt.addingTimeInterval(Self.sourceDateTolerance)
        return unclaimed(range)
            .filter { abs($0.duration - source.duration) <= Self.sourceDurationTolerance }
            .map(\.localID)
    }

    func fits(_ clip: LibraryClip) -> [String] {
        let range = clip.savedAt.addingTimeInterval(-Self.exportLead)
            ... clip.savedAt.addingTimeInterval(Self.exportLag)
        let expected = exportedDuration(of: clip)
        return unclaimed(range)
            .filter { abs($0.duration - expected) <= Self.exportDurationTolerance }
            .map(\.localID)
    }

    /// Each record that fits exactly one video which fits no other record, with that video.
    static func uniquePairs(_ fits: [(Record, [String])]) -> [(Record, String)] {
        var fitting: [String: Int] = [:]
        for (_, localIDs) in fits {
            for localID in Set(localIDs) { fitting[localID, default: 0] += 1 }
        }
        return fits.compactMap { entry -> (Record, String)? in
            let (record, localIDs) = entry
            guard localIDs.count == 1, let localID = localIDs.first, fitting[localID] == 1 else { return nil }
            return (record, localID)
        }
    }

    /// The duration the exporter gave a clip: its window, trimmed to its source.
    private func exportedDuration(of clip: LibraryClip) -> TimeInterval {
        let end = sourceDurations[clip.sourceAssetID].map { min(clip.endTime, $0) } ?? clip.endTime
        return max(0, end - max(0, clip.startTime))
    }

    /// The videos created within `range` no record holds.
    private func unclaimed(_ range: ClosedRange<Date>) -> [LibraryAssetCandidate] {
        lookup.videos(range).filter { !claimed.contains($0.localID) }
    }
}

/// A random mark minted once per device and kept in the Keychain as never migrating to another
/// device, so the clip library can tell a record saved on this device from one restored onto it
/// from a backup of another. `nil` when the Keychain can't be read or written.
enum DeviceMark {
    private static let name = "device-mark"

    static func current(
        store: SecretStore = KeychainSecretStore(service: "com.hoiekim.turnip.device")
    ) -> String? {
        if let mark = store.value(for: name) { return mark }
        store.setValue(UUID().uuidString, for: name)
        return store.value(for: name)
    }
}
