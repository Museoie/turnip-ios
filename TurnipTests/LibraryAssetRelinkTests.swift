import XCTest
@testable import Turnip

/// A stand-in Photos library: each asset's local identifier on this device, its iCloud identifier,
/// and its creation date and duration.
private struct FakePhotos {
    struct Asset: Sendable {
        let localID: String
        var cloudID: String?
        var createdAt = Date(timeIntervalSince1970: 0)
        var duration: TimeInterval = 0
    }

    var assets: [Asset]
    var wholeLibrary = true

    var lookup: LibraryAssetLookup {
        let assets = assets
        let wholeLibrary = wholeLibrary
        return LibraryAssetLookup(
            canReadWholeLibrary: { wholeLibrary },
            existing: { localIDs in
                Set(assets.map(\.localID)).intersection(localIDs)
            },
            cloudIDs: { localIDs in
                var found: [String: String] = [:]
                for asset in assets where localIDs.contains(asset.localID) { found[asset.localID] = asset.cloudID }
                return found
            },
            localIDs: { cloudIDs in
                var found: [String: String] = [:]
                for asset in assets {
                    guard let cloudID = asset.cloudID, cloudIDs.contains(cloudID) else { continue }
                    found[cloudID] = asset.localID
                }
                return found
            },
            videos: { range in
                assets.filter { range.contains($0.createdAt) }
                    .map { LibraryAssetCandidate(localID: $0.localID, duration: $0.duration) }
            })
    }
}

/// A clip library restored onto a new iPhone holds the old iPhone's Photos identifiers, which name
/// nothing there: its records find their videos again by iCloud identifier, or, for records saved
/// before the library kept those, by date and duration.
@MainActor
final class LibraryAssetRelinkTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("library.json") }
    private let recorded = Date(timeIntervalSince1970: 1_790_000_000)
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-relink-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLibrary() -> ClipLibrary {
        ClipLibrary(
            fileURL: fileURL, vocabulary: { .seed }, now: { [clock] in clock }, announce: { _ in })
    }

    private func savedClip(
        _ start: TimeInterval, length: TimeInterval = 1.5, export: String, id: UUID = UUID(), poseID: String? = nil
    ) -> LibrarySave.Clip {
        LibrarySave.Clip(
            id: id, window: TrickWindow(startTime: start, endTime: start + length), exportAssetID: export,
            names: [], isMe: true, isAutoDetected: true, proposal: nil, poseID: poseID)
    }

    /// A library on the device that saved it, with one clip of one video.
    private func savedLibrary(
        clip: UUID = UUID(), export: String = "old-export", source: String = "old-source"
    ) -> ClipLibrary {
        let library = makeLibrary()
        library.record(
            LibrarySave(
                sourceAssetID: source, sourceDuration: 30,
                clips: [savedClip(4, export: export, id: clip, poseID: "pose-a")],
                dismissedWindows: [
                    DismissedWindow(sourceAssetID: source, poseID: "pose-a", startFrame: 100, endFrame: 115)
                ]),
            sourceRecordedAt: recorded)
        return library
    }

    private let oldPhotos = FakePhotos(assets: [
        .init(localID: "old-export", cloudID: "cloud-export"),
        .init(localID: "old-source", cloudID: "cloud-source")
    ])

    // MARK: - By iCloud identifier

    func testTheDeviceThatSavedAClipKeepsItsVideosICloudIdentifiers() async {
        let library = savedLibrary()
        await library.relinkAssets(using: oldPhotos.lookup)

        XCTAssertEqual(library.clips.first?.exportAssetID, "old-export")
        XCTAssertEqual(library.clips.first?.exportCloudID, "cloud-export")
        XCTAssertEqual(library.sources.first?.cloudID, "cloud-source")
        XCTAssertEqual(makeLibrary().clips, library.clips)
        XCTAssertEqual(makeLibrary().sources, library.sources)
    }

    func testARestoredLibraryFindsItsVideosByTheirICloudIdentifiers() async {
        let clipID = UUID()
        await savedLibrary(clip: clipID).relinkAssets(using: oldPhotos.lookup)

        let restored = makeLibrary()
        let newPhotos = FakePhotos(assets: [
            .init(localID: "new-export", cloudID: "cloud-export"),
            .init(localID: "new-source", cloudID: "cloud-source")
        ])
        await restored.relinkAssets(using: newPhotos.lookup)

        let clip = restored.clip(clipID)
        XCTAssertEqual(clip?.exportAssetID, "new-export")
        XCTAssertEqual(clip?.exportCloudID, "cloud-export")
        XCTAssertEqual(clip?.sourceAssetID, "new-source")
        XCTAssertEqual(
            restored.sources,
            [LibrarySource(assetID: "new-source", cloudID: "cloud-source", recordedAt: recorded, duration: 30)])
        XCTAssertEqual(restored.dismissedWindows.map(\.sourceAssetID), ["new-source"])

        let relaunched = makeLibrary()
        XCTAssertEqual(relaunched.clips, restored.clips)
        XCTAssertEqual(relaunched.sources, restored.sources)
        XCTAssertEqual(relaunched.dismissedWindows, restored.dismissedWindows)
    }

    /// iCloud Photos brings a restored device's videos down over time: a video not there yet keeps
    /// its record as it was, and a later pass finds it.
    func testAVideoICloudHasntBroughtDownYetIsFoundOnALaterPass() async {
        await savedLibrary().relinkAssets(using: oldPhotos.lookup)
        let restored = makeLibrary()

        await restored.relinkAssets(using: FakePhotos(assets: []).lookup)
        XCTAssertEqual(restored.clips.first?.exportAssetID, "old-export")
        XCTAssertEqual(restored.clips.first?.exportCloudID, "cloud-export")

        let arrived = FakePhotos(assets: [.init(localID: "new-export", cloudID: "cloud-export")])
        await restored.relinkAssets(using: arrived.lookup)
        XCTAssertEqual(restored.clips.first?.exportAssetID, "new-export")
    }

    /// Under limited access a video outside the selection looks gone: its record waits for full
    /// access rather than being relinked, while the videos the app can see still get their iCloud
    /// identifiers.
    func testUnderLimitedAccessAMissingVideoWaitsAndAFoundOneGetsItsICloudIdentifier() async {
        await savedLibrary().relinkAssets(using: oldPhotos.lookup)
        let restored = makeLibrary()
        restored.record(
            LibrarySave(
                sourceAssetID: "other-source", sourceDuration: 30, clips: [savedClip(2, export: "other-export")]),
            sourceRecordedAt: recorded)

        var photos = FakePhotos(assets: [
            .init(localID: "new-export", cloudID: "cloud-export"),
            .init(localID: "other-export", cloudID: "cloud-other")
        ])
        photos.wholeLibrary = false
        await restored.relinkAssets(using: photos.lookup)

        XCTAssertEqual(restored.clips.map(\.exportAssetID), ["old-export", "other-export"])
        XCTAssertEqual(restored.clips.map(\.exportCloudID), ["cloud-export", "cloud-other"])
    }

    /// The same video saved again on the new device before the pass ran has a record of its own:
    /// the restored one joins it.
    func testAVideoSavedAgainOnTheNewDeviceJoinsItsRestoredRecord() async {
        await savedLibrary().relinkAssets(using: oldPhotos.lookup)
        let restored = makeLibrary()
        restored.record(
            LibrarySave(
                sourceAssetID: "new-source", sourceDuration: 30, clips: [savedClip(12, export: "export-b")]),
            sourceRecordedAt: recorded)

        let newPhotos = FakePhotos(assets: [
            .init(localID: "new-export", cloudID: "cloud-export"),
            .init(localID: "new-source", cloudID: "cloud-source"),
            .init(localID: "export-b", cloudID: "cloud-b")
        ])
        await restored.relinkAssets(using: newPhotos.lookup)

        XCTAssertEqual(
            restored.sources,
            [LibrarySource(assetID: "new-source", cloudID: "cloud-source", recordedAt: recorded, duration: 30)])
        XCTAssertEqual(restored.clips.map(\.sourceAssetID), ["new-source", "new-source"])
    }

    /// A clip saved again gets a new video; the iCloud identifier of the one it replaced goes with it.
    func testSavingAClipAgainWithANewVideoDropsTheOldICloudIdentifier() async {
        let clipID = UUID()
        let library = savedLibrary(clip: clipID)
        await library.relinkAssets(using: oldPhotos.lookup)
        XCTAssertEqual(library.clip(clipID)?.exportCloudID, "cloud-export")

        library.record(
            LibrarySave(
                sourceAssetID: "old-source", sourceDuration: 30,
                clips: [savedClip(4, export: "re-export", id: clipID)]),
            sourceRecordedAt: recorded)
        XCTAssertEqual(library.clip(clipID)?.exportAssetID, "re-export")
        XCTAssertNil(library.clip(clipID)?.exportCloudID)
        XCTAssertEqual(library.sources.first?.cloudID, "cloud-source")
    }

    // MARK: - Saved before the library kept iCloud identifiers

    /// A source matches by the creation date and duration the library read from it, an exported
    /// clip by its window's duration and a creation date during its save. The iCloud identifiers
    /// are kept as they're found.
    func testALibrarySavedBeforeICloudIdentifiersFindsItsVideosByDateAndDuration() async {
        let restored = savedLibrary()
        let newPhotos = FakePhotos(assets: [
            .init(localID: "new-source", cloudID: "cloud-source", createdAt: recorded, duration: 30.1),
            .init(
                localID: "new-export", cloudID: "cloud-export", createdAt: clock.addingTimeInterval(-20),
                duration: 1.52),
            .init(localID: "unrelated", createdAt: clock.addingTimeInterval(-30), duration: 4)
        ])
        await restored.relinkAssets(using: newPhotos.lookup)

        XCTAssertEqual(restored.clips.first?.exportAssetID, "new-export")
        XCTAssertEqual(restored.clips.first?.exportCloudID, "cloud-export")
        XCTAssertEqual(restored.clips.first?.sourceAssetID, "new-source")
        XCTAssertEqual(restored.sources.first?.cloudID, "cloud-source")
    }

    /// Two videos that could be the clip's leave it alone: a clip shown with another clip's video
    /// is worse than one shown as missing.
    func testALegacyClipWithTwoMatchingVideosIsLeftAlone() async {
        let restored = savedLibrary()
        await restored.relinkAssets(using: FakePhotos(assets: [
            .init(localID: "first", createdAt: clock.addingTimeInterval(-20), duration: 1.5),
            .init(localID: "second", createdAt: clock.addingTimeInterval(-10), duration: 1.5)
        ]).lookup)
        XCTAssertEqual(restored.clips.first?.exportAssetID, "old-export")
    }

    /// A video another record already holds is never taken for a second one.
    func testALegacyClipIsNotGivenAVideoAnotherClipHolds() async {
        let restored = makeLibrary()
        restored.record(
            LibrarySave(
                sourceAssetID: "source", sourceDuration: 30,
                clips: [savedClip(2, export: "held"), savedClip(8, export: "old-export")]),
            sourceRecordedAt: recorded)
        await restored.relinkAssets(using: FakePhotos(assets: [
            .init(localID: "held", createdAt: clock.addingTimeInterval(-20), duration: 1.5)
        ]).lookup)
        XCTAssertEqual(restored.clips.map(\.exportAssetID), ["held", "old-export"])
    }

    /// One clip matching two videos becomes unique once another clip takes one of them.
    func testAMatchAnotherClipTakesLeavesTheFirstWithOne() async {
        let restored = makeLibrary()
        restored.record(
            LibrarySave(
                sourceAssetID: "source", sourceDuration: 30,
                clips: [savedClip(2, length: 1.5, export: "old-a"), savedClip(8, length: 1.9, export: "old-b")]),
            sourceRecordedAt: recorded)
        await restored.relinkAssets(using: FakePhotos(assets: [
            .init(localID: "new-a", createdAt: clock.addingTimeInterval(-20), duration: 1.5),
            .init(localID: "new-b", createdAt: clock.addingTimeInterval(-10), duration: 1.7)
        ]).lookup)
        XCTAssertEqual(restored.clips.map(\.exportAssetID), ["new-a", "new-b"])
    }

    /// A video created long before the save can't be the clip it exported.
    func testALegacyClipIsNotMatchedOutsideItsSave() async {
        let restored = savedLibrary()
        await restored.relinkAssets(using: FakePhotos(assets: [
            .init(localID: "earlier", createdAt: clock.addingTimeInterval(-2 * 60 * 60), duration: 1.5)
        ]).lookup)
        XCTAssertEqual(restored.clips.first?.exportAssetID, "old-export")
    }
}
