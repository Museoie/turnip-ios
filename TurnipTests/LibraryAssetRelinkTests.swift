import XCTest
@testable import Turnip

/// Holds a relink pass inside its first Photos lookup until the test lets it go.
private final class PassGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func pass() {
        entered.signal()
        release.wait()
    }
}

/// Counts relink passes by their first Photos lookup.
private final class PassCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

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
    var gate: PassGate?
    var counter: PassCounter?

    var lookup: LibraryAssetLookup {
        let assets = assets
        let wholeLibrary = wholeLibrary
        let gate = gate
        let counter = counter
        return LibraryAssetLookup(
            canReadWholeLibrary: { wholeLibrary },
            existing: { localIDs in
                counter?.increment()
                gate?.pass()
                return Set(assets.map(\.localID)).intersection(localIDs)
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
/// nothing there: its records find their videos again by iCloud identifier, or, for records with
/// none that were saved on another device, by date and duration.
@MainActor
final class LibraryAssetRelinkTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("library.json") }
    private let recorded = Date(timeIntervalSince1970: 1_790_000_000)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-relink-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// The library file as the app on `device` opens it; a `nil` device is a build from before the
    /// library stamped its records.
    private func makeLibrary(on device: String?) -> ClipLibrary {
        ClipLibrary(
            fileURL: fileURL, vocabulary: { .seed }, now: { [unowned self] in clock }, announce: { _ in },
            deviceMark: { device })
    }

    private func savedClip(
        _ start: TimeInterval, length: TimeInterval = 1.5, export: String, id: UUID = UUID(), poseID: String? = nil
    ) -> LibrarySave.Clip {
        LibrarySave.Clip(
            id: id, window: TrickWindow(startTime: start, endTime: start + length), exportAssetID: export,
            names: [], isMe: true, isAutoDetected: true, proposal: nil, poseID: poseID)
    }

    /// A library with one clip of one video, saved on `device`.
    private func savedLibrary(
        on device: String?, clip: UUID = UUID(), export: String = "old-export", source: String = "old-source"
    ) -> ClipLibrary {
        let library = makeLibrary(on: device)
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

    /// A library saved on the old phone, which has kept its videos' iCloud identifiers, as the new
    /// phone opens it.
    private func restoredLibrary(clip: UUID = UUID()) async -> ClipLibrary {
        await savedLibrary(on: "old-phone", clip: clip).relinkAssets(using: oldPhotos.lookup)
        return makeLibrary(on: "new-phone")
    }

    // MARK: - By iCloud identifier

    func testTheDeviceThatSavedAClipKeepsItsVideosICloudIdentifiers() async {
        let library = savedLibrary(on: "old-phone")
        await library.relinkAssets(using: oldPhotos.lookup)

        XCTAssertEqual(library.clips.first?.exportAssetID, "old-export")
        XCTAssertEqual(library.clips.first?.exportCloudID, "cloud-export")
        XCTAssertEqual(library.clips.first?.savedOn, "old-phone")
        XCTAssertEqual(library.sources.first?.cloudID, "cloud-source")
        XCTAssertEqual(library.sources.first?.savedOn, "old-phone")
        XCTAssertEqual(makeLibrary(on: "old-phone").clips, library.clips)
        XCTAssertEqual(makeLibrary(on: "old-phone").sources, library.sources)
    }

    func testARestoredLibraryFindsItsVideosByTheirICloudIdentifiers() async {
        let clipID = UUID()
        let restored = await restoredLibrary(clip: clipID)
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
            [LibrarySource(
                assetID: "new-source", cloudID: "cloud-source", savedOn: "old-phone", recordedAt: recorded,
                duration: 30)])
        XCTAssertEqual(restored.dismissedWindows.map(\.sourceAssetID), ["new-source"])

        let relaunched = makeLibrary(on: "new-phone")
        XCTAssertEqual(relaunched.clips, restored.clips)
        XCTAssertEqual(relaunched.sources, restored.sources)
        XCTAssertEqual(relaunched.dismissedWindows, restored.dismissedWindows)
    }

    /// iCloud Photos brings a restored device's videos down over time: a video not there yet keeps
    /// its record as it was, and a later pass finds it.
    func testAVideoICloudHasntBroughtDownYetIsFoundOnALaterPass() async {
        let restored = await restoredLibrary()

        await restored.relinkAssets(using: FakePhotos(assets: []).lookup)
        XCTAssertEqual(restored.clips.first?.exportAssetID, "old-export")
        XCTAssertEqual(restored.clips.first?.exportCloudID, "cloud-export")

        let arrived = FakePhotos(assets: [.init(localID: "new-export", cloudID: "cloud-export")])
        await restored.relinkAssets(using: arrived.lookup)
        XCTAssertEqual(restored.clips.first?.exportAssetID, "new-export")
    }

    /// The same video saved again on the new device before the pass ran has a record of its own:
    /// the restored one joins it.
    func testAVideoSavedAgainOnTheNewDeviceJoinsItsRestoredRecord() async {
        let restored = await restoredLibrary()
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
            [LibrarySource(
                assetID: "new-source", cloudID: "cloud-source", savedOn: "new-phone", recordedAt: recorded,
                duration: 30)])
        XCTAssertEqual(restored.clips.map(\.sourceAssetID), ["new-source", "new-source"])
    }

    /// A clip saved again gets a new video; the iCloud identifier of the one it replaced goes with it.
    func testSavingAClipAgainWithANewVideoDropsTheOldICloudIdentifier() async {
        let clipID = UUID()
        let library = savedLibrary(on: "old-phone", clip: clipID)
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

    /// A save made while a pass waits on Photos keeps its video: the pass only changes a record that
    /// still holds what it read.
    func testAClipSavedAgainDuringAPassKeepsItsNewVideo() async {
        let clipID = UUID()
        let restored = await restoredLibrary(clip: clipID)
        var newPhotos = FakePhotos(assets: [.init(localID: "new-export", cloudID: "cloud-export")])
        let gate = PassGate()
        newPhotos.gate = gate

        let lookup = newPhotos.lookup
        let pass = Task { await restored.relinkAssets(using: lookup) }
        var entered = false
        let deadline = Date().addingTimeInterval(5)
        while !entered, Date() < deadline {
            entered = gate.entered.wait(timeout: .now()) == .success
            if !entered { await Task.yield() }
        }
        XCTAssertTrue(entered, "the pass never reached Photos")

        restored.record(
            LibrarySave(
                sourceAssetID: "old-source", sourceDuration: 30,
                clips: [savedClip(4, export: "re-export", id: clipID)]),
            sourceRecordedAt: recorded)
        gate.release.signal()
        await pass.value

        XCTAssertEqual(restored.clip(clipID)?.exportAssetID, "re-export")
        XCTAssertNil(restored.clip(clipID)?.exportCloudID)
    }

    /// The Profile starts a pass whenever it appears and the app becomes active, but asks Photos at
    /// most once per interval.
    func testTheProfilesPassesComeAtMostOncePerInterval() async {
        let library = savedLibrary(on: "old-phone")
        var photos = oldPhotos
        let counter = PassCounter()
        photos.counter = counter

        await library.relinkAssetsIfDue(using: photos.lookup)
        clock = clock.addingTimeInterval(60)
        await library.relinkAssetsIfDue(using: photos.lookup)
        XCTAssertEqual(counter.count, 1)

        clock = clock.addingTimeInterval(ClipLibrary.relinkInterval)
        await library.relinkAssetsIfDue(using: photos.lookup)
        XCTAssertEqual(counter.count, 2)
    }

    // MARK: - By date and duration

    /// A library saved before the library kept iCloud identifiers, opened on a new phone: a source
    /// matches by the creation date and duration the library read from it, an exported clip by its
    /// window's duration and a creation date during its save. The iCloud identifiers are kept as
    /// they're found.
    func testALibrarySavedBeforeICloudIdentifiersFindsItsVideosOnANewPhone() async {
        _ = savedLibrary(on: nil)
        let restored = makeLibrary(on: "new-phone")
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

    /// Under limited access a video outside the selection looks gone, so the match by date and
    /// duration waits for full access; the map by iCloud identifier is exact and doesn't.
    func testUnderLimitedAccessOnlyTheICloudMatchRuns() async {
        let library = savedLibrary(on: nil)
        await library.relinkAssets(using: oldPhotos.lookup)
        library.record(
            LibrarySave(sourceAssetID: "source-b", sourceDuration: 30, clips: [savedClip(2, export: "old-b")]),
            sourceRecordedAt: nil)
        let restored = makeLibrary(on: "new-phone")
        var newPhotos = FakePhotos(assets: [
            .init(localID: "new-export", cloudID: "cloud-export"),
            .init(localID: "new-b", createdAt: clock.addingTimeInterval(-20), duration: 1.5)
        ])
        newPhotos.wholeLibrary = false

        await restored.relinkAssets(using: newPhotos.lookup)
        XCTAssertEqual(restored.clips.map(\.exportAssetID), ["new-export", "old-b"])

        newPhotos.wholeLibrary = true
        await restored.relinkAssets(using: newPhotos.lookup)
        XCTAssertEqual(restored.clips.map(\.exportAssetID), ["new-export", "new-b"])
    }

    /// A clip whose video was deleted in Photos on the phone that saved it stays without one, even
    /// with a video there that would fit it: whether it was saved before or after the library
    /// stamped its records.
    func testOnThePhoneThatSavedItAClipDeletedInPhotosIsNotMatched() async {
        let library = makeLibrary(on: nil)
        library.record(
            LibrarySave(
                sourceAssetID: "source", sourceDuration: 30,
                clips: [savedClip(2, export: "kept"), savedClip(8, length: 2.5, export: "deleted-before")]),
            sourceRecordedAt: recorded)
        let updated = makeLibrary(on: "old-phone")
        updated.record(
            LibrarySave(
                sourceAssetID: "source", sourceDuration: 30,
                clips: [savedClip(14, length: 3.5, export: "deleted-after")]),
            sourceRecordedAt: recorded)
        let photos = FakePhotos(assets: [
            .init(localID: "kept", createdAt: clock.addingTimeInterval(-40), duration: 1.5),
            .init(localID: "camera-a", createdAt: clock.addingTimeInterval(-30), duration: 2.5),
            .init(localID: "camera-b", createdAt: clock.addingTimeInterval(-20), duration: 3.5)
        ])

        await updated.relinkAssets(using: photos.lookup)
        XCTAssertEqual(updated.clips.map(\.exportAssetID), ["kept", "deleted-before", "deleted-after"])
        await makeLibrary(on: "old-phone").relinkAssets(using: photos.lookup)
        XCTAssertEqual(
            makeLibrary(on: "old-phone").clips.map(\.exportAssetID), ["kept", "deleted-before", "deleted-after"])
    }

    /// Two clips of one save so close in length that each fits the other's video: the one video
    /// that has arrived goes to neither, rather than to whichever clip comes first.
    func testAVideoTwoClipsCouldBeIsGivenToNeither() async {
        let library = makeLibrary(on: nil)
        library.record(
            LibrarySave(
                sourceAssetID: "source", sourceDuration: 30,
                clips: [savedClip(2, length: 1.6, export: "old-a"), savedClip(8, length: 1.65, export: "old-b")]),
            sourceRecordedAt: recorded)
        let restored = makeLibrary(on: "new-phone")
        await restored.relinkAssets(using: FakePhotos(assets: [
            .init(localID: "new-b", createdAt: clock.addingTimeInterval(-10), duration: 1.65)
        ]).lookup)
        XCTAssertEqual(restored.clips.map(\.exportAssetID), ["old-a", "old-b"])
    }

    /// Two videos that could be the clip's leave it alone.
    func testAClipTwoVideosCouldBeIsLeftAlone() async {
        _ = savedLibrary(on: nil)
        let restored = makeLibrary(on: "new-phone")
        await restored.relinkAssets(using: FakePhotos(assets: [
            .init(localID: "first", createdAt: clock.addingTimeInterval(-20), duration: 1.5),
            .init(localID: "second", createdAt: clock.addingTimeInterval(-10), duration: 1.5)
        ]).lookup)
        XCTAssertEqual(restored.clips.first?.exportAssetID, "old-export")
    }

    /// Clips saved with iCloud Photos off have no iCloud identifier and match on a new phone by date
    /// and duration, but never to a video another record holds.
    func testAClipWithoutAnICloudIdentifierIsNotGivenAVideoAnotherClipHolds() async {
        let library = makeLibrary(on: "old-phone")
        library.record(
            LibrarySave(
                sourceAssetID: "source", sourceDuration: 30,
                clips: [
                    savedClip(2, export: "held"), savedClip(8, export: "old-b"),
                    savedClip(14, length: 2.5, export: "old-c")
                ]),
            sourceRecordedAt: recorded)
        let restored = makeLibrary(on: "new-phone")
        await restored.relinkAssets(using: FakePhotos(assets: [
            .init(localID: "held", createdAt: clock.addingTimeInterval(-30), duration: 1.5),
            .init(localID: "new-c", createdAt: clock.addingTimeInterval(-20), duration: 2.5)
        ]).lookup)
        XCTAssertEqual(restored.clips.map(\.exportAssetID), ["held", "old-b", "new-c"])
    }

    /// A video created long before the save can't be the clip it exported.
    func testAClipIsNotMatchedOutsideItsSave() async {
        _ = savedLibrary(on: nil)
        let restored = makeLibrary(on: "new-phone")
        await restored.relinkAssets(using: FakePhotos(assets: [
            .init(localID: "earlier", createdAt: clock.addingTimeInterval(-2 * 60 * 60), duration: 1.5)
        ]).lookup)
        XCTAssertEqual(restored.clips.first?.exportAssetID, "old-export")
    }
}
