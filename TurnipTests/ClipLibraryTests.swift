import AVFoundation
import UIKit
import XCTest
@testable import Turnip

@MainActor
final class ClipLibraryTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("library.json") }
    private let recorded = Date(timeIntervalSince1970: 1_790_000_000)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var spoken: [String] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-library-test-\(UUID().uuidString)", isDirectory: true)
        spoken = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLibrary() -> ClipLibrary {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return ClipLibrary(
            fileURL: fileURL, vocabulary: { .seed }, calendar: utc, now: { [unowned self] in clock },
            announce: { [unowned self] in spoken.append($0) })
    }

    private func savedClip(
        _ start: TimeInterval, export: String = "export-1", names: [String] = [], isMe: Bool = true,
        id: UUID = UUID()
    ) -> LibrarySave.Clip {
        LibrarySave.Clip(
            id: id, window: TrickWindow(startTime: start, endTime: start + 1.5), exportAssetID: export,
            names: names.map { ClipName(name: $0, origin: .typed) }, isMe: isMe, isAutoDetected: true)
    }

    private func save(_ clips: [LibrarySave.Clip], source: String = "source-1") -> LibrarySave {
        LibrarySave(sourceAssetID: source, sourceDuration: 30, clips: clips)
    }

    // MARK: - Recording a save

    func testASaveIsReadBackByTheNextLaunch() {
        let library = makeLibrary()
        library.record(
            save([savedClip(4, names: ["gainer"]), savedClip(9, export: "export-2")]), sourceRecordedAt: recorded)

        let relaunched = makeLibrary()
        XCTAssertEqual(relaunched.clips, library.clips)
        XCTAssertEqual(relaunched.clips.count, 2)
        XCTAssertEqual(relaunched.sources, [LibrarySource(assetID: "source-1", recordedAt: recorded, duration: 30)])
        XCTAssertEqual(relaunched.earned, library.earned)
    }

    /// A clip is dated by when its trick happened — the video's recording date plus its offset — so
    /// a session that runs past midnight counts on both days.
    func testAClipIsDatedByItsSourcePlusItsOffset() {
        let library = makeLibrary()
        library.record(save([savedClip(42)]), sourceRecordedAt: recorded)
        XCTAssertEqual(library.clips.first?.recordedAt, recorded.addingTimeInterval(42))
        XCTAssertEqual(library.clips.first?.savedAt, clock)
    }

    func testAVideoWithoutARecordingDateDatesItsClipsBySave() {
        let library = makeLibrary()
        library.record(save([savedClip(42)]), sourceRecordedAt: nil)
        XCTAssertEqual(library.clips.first?.recordedAt, clock)
    }

    /// A retry after a partial failure, or a clip edited and saved again, updates the record it
    /// already has: its new asset and names, its first save's date kept.
    func testSavingAClipAgainUpdatesItsRecordInPlace() {
        let library = makeLibrary()
        let id = UUID()
        library.record(save([savedClip(4, export: "first", id: id)]), sourceRecordedAt: recorded)
        let firstSave = clock
        clock = clock.addingTimeInterval(60)
        library.record(save([savedClip(5, export: "second", names: ["cork"], id: id)]), sourceRecordedAt: recorded)

        XCTAssertEqual(library.clips.count, 1)
        XCTAssertEqual(library.clips.first?.exportAssetID, "second")
        XCTAssertEqual(library.clips.first?.names.map(\.name), ["cork"])
        XCTAssertEqual(library.clips.first?.startTime, 5)
        XCTAssertEqual(library.clips.first?.savedAt, firstSave)
    }

    /// A save's achievements are returned for the save's own announcement, not spoken twice.
    func testASaveReturnsWhatItEarnedWithoutAnnouncingIt() {
        let library = makeLibrary()
        let earned = library.record(save([savedClip(4, names: ["gainer"])]), sourceRecordedAt: recorded)
        XCTAssertEqual(earned, [EarnedAchievement(trick: "gainer", kind: .level, step: 1, earnedAt: clock)])
        XCTAssertEqual(spoken, [])
    }

    // MARK: - The file

    /// A file this build can't read is moved aside, never overwritten: a later build, or a fix,
    /// may still read what it holds.
    func testAnUnreadableFileIsSetAsideAndTheLibraryStartsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let library = makeLibrary()
        XCTAssertEqual(library.clips, [])
        library.record(save([savedClip(1)]), sourceRecordedAt: recorded)

        let setAside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("library-unreadable-") }
        XCTAssertEqual(setAside.count, 1)
        let kept = try Data(contentsOf: directory.appendingPathComponent(setAside[0]))
        XCTAssertEqual(kept, Data("not json".utf8))
        XCTAssertEqual(makeLibrary().clips.count, 1)
    }

    func testAFileFromANewerSchemaIsSetAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let newer = #"{"schemaVersion": 2, "sources": [], "clips": [], "earned": [], "favorites": []}"#
        try Data(newer.utf8).write(to: fileURL)

        _ = makeLibrary()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains("library.json"))
        XCTAssertEqual(names.filter { $0.hasPrefix("library-unreadable-") }.count, 1)
    }

    func testTheFileCarriesItsSchemaVersion() throws {
        makeLibrary().record(save([savedClip(1)]), sourceRecordedAt: recorded)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, ClipLibrary.schemaVersion)
    }

    /// In the device backup and never evicted: not `Caches/`, not `Documents/`.
    func testTheLibraryLivesInApplicationSupport() throws {
        let path = try XCTUnwrap(ClipLibrary.defaultFileURL?.path)
        XCTAssertTrue(path.contains("/Library/Application Support/"), path)
    }

    // MARK: - Editing saved clips

    func testNamingASavedClipPersistsAndAnnouncesWhatItEarned() {
        let library = makeLibrary()
        library.record(save([savedClip(4)]), sourceRecordedAt: recorded)
        let id = library.clips[0].id

        library.addName(" Gainer ", origin: .typed, to: id)
        library.addName("gainer", origin: .vocabulary, to: id)

        XCTAssertEqual(makeLibrary().clips.first?.names, [ClipName(name: "Gainer", origin: .typed)])
        XCTAssertEqual(spoken, ["Earned Gainer, level 1"])
    }

    func testRemovingAndCorrectingNamesFollowNameClipsRules() {
        let library = makeLibrary()
        library.record(save([savedClip(4, names: ["corck", "gainer"])]), sourceRecordedAt: recorded)
        let id = library.clips[0].id

        library.replaceName(ClipName(name: "corck", origin: .typed), with: "cork", in: id)
        library.removeName(ClipName(name: "gainer", origin: .typed), from: id)

        XCTAssertEqual(library.clip(id)?.names, [ClipName(name: "cork", origin: .vocabulary)])
    }

    /// A clip marked as someone else's counts toward nothing, but what it earned stays earned.
    func testMarkingAClipSomeoneElsesKeepsWhatItEarned() {
        let library = makeLibrary()
        library.record(save([savedClip(4, names: ["gainer"])]), sourceRecordedAt: recorded)
        library.setIsMe(false, for: library.clips[0].id)

        XCTAssertEqual(library.clips.first?.isMe, false)
        XCTAssertEqual(library.earned.map(\.step), [1])
        let progress = Achievements.progress(
            counts: Achievements.counts(of: library.clips, vocabulary: .seed, calendar: .current),
            earned: library.earned, vocabulary: .seed)
        XCTAssertEqual(progress.first?.level, 1)
        XCTAssertEqual(progress.first?.sessions, 0)
    }

    func testDeletingAVideosLastClipRemovesTheVideoButNotWhatItEarned() {
        let library = makeLibrary()
        library.record(save([savedClip(1, names: ["cork"]), savedClip(5)]), sourceRecordedAt: recorded)
        library.delete(library.clips[0].id)
        XCTAssertEqual(library.sources.count, 1)
        library.delete(library.clips[0].id)

        XCTAssertEqual(library.clips, [])
        XCTAssertEqual(library.sources, [])
        XCTAssertEqual(makeLibrary().earned.map(\.trick), ["cork"])
    }

    /// "Needs a name" opens on the most recent video first, each video's clips in the order they
    /// happen.
    func testUnnamedClipsComeNewestVideoFirstInClipOrder() {
        let library = makeLibrary()
        library.record(save([savedClip(8), savedClip(2), savedClip(5, names: ["hook"])], source: "old"),
                       sourceRecordedAt: recorded)
        library.record(save([savedClip(3)], source: "new"), sourceRecordedAt: recorded.addingTimeInterval(86_400))

        XCTAssertEqual(library.unnamedClips.map(\.sourceAssetID), ["new", "old", "old"])
        XCTAssertEqual(library.unnamedClips.map(\.startTime), [3, 2, 8])
    }

    func testNamesUsedOnAVideoComeOnceInClipOrder() {
        let library = makeLibrary()
        library.record(save([savedClip(9, names: ["cork"]), savedClip(1, names: ["Gainer", "cork"]), savedClip(5)]),
                       sourceRecordedAt: recorded)
        library.record(save([savedClip(1, names: ["hook"])], source: "other"), sourceRecordedAt: recorded)
        let unnamed = library.unnamedClips[0]
        XCTAssertEqual(library.namesUsed(alongside: unnamed), ["Gainer", "cork"])
    }

    // MARK: - Name Clips' save writes the library

    private func nameClipsModel(
        _ items: [ClipListItem],
        saveToPhotos: @escaping SaveOneClipToPhotos = { url, _ in "asset-\(url.lastPathComponent)" },
        recordSaved: @escaping RecordSavedClips,
        announceAfterScreenChange: @escaping AccessibilityAnnouncing = { _ in }
    ) -> ClipListViewModel {
        ClipListViewModel(
            items: items, asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "source-1", duration: 30,
            exportClip: { spec, _, directory, _ in
                directory.appendingPathComponent("clip-\(Int(spec.window.startTime)).mp4")
            },
            saveToPhotos: saveToPhotos, deleteOriginalAsset: { _ in }, recordSaved: recordSaved,
            makeDirectory: {
                FileManager.default.temporaryDirectory.appendingPathComponent("turnip-test-\(UUID().uuidString)")
            },
            settingsProvider: { TurnipSettings() }, announce: { _ in },
            announceAfterScreenChange: announceAfterScreenChange)
    }

    private func item(_ start: TimeInterval, names: [String] = [], isMe: Bool = true) -> ClipListItem {
        ClipListItem(
            window: TrickWindow(startTime: start, endTime: start + 1),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1),
            names: names.map { ClipName(name: $0, origin: .vocabulary) }, isMe: isMe, isAutoDetected: true)
    }

    func testSaveRecordsEachClipWithItsPhotosAssetAndNames() async {
        var saves: [LibrarySave] = []
        let model = nameClipsModel(
            [item(2, names: ["gainer"]), item(6, isMe: false)], recordSaved: { saves.append($0); return [] })

        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves[0].sourceAssetID, "source-1")
        XCTAssertEqual(saves[0].clips.map(\.exportAssetID), ["asset-clip-2.mp4", "asset-clip-6.mp4"])
        XCTAssertEqual(saves[0].clips.map(\.id), model.clipsToName.map(\.id))
        XCTAssertEqual(saves[0].clips.map(\.names), [[ClipName(name: "gainer", origin: .vocabulary)], []])
        XCTAssertEqual(saves[0].clips.map(\.isMe), [true, false])
    }

    /// A clip that landed in Photos is in the library even when another clip failed, and a name
    /// given before the retry reaches the library with the retry.
    func testAPartialFailureRecordsWhatLandedAndTheRetryCarriesNewNames() async {
        actor Photos {
            var isRejecting = true
            func accept() { isRejecting = false }
        }
        var saves: [LibrarySave] = []
        let photos = Photos()
        let model = nameClipsModel(
            [item(2), item(6)],
            saveToPhotos: { url, _ in
                if url.lastPathComponent == "clip-6.mp4", await photos.isRejecting {
                    throw ClipSaveError.photosSaveFailed(reason: "denied")
                }
                return "asset-\(url.lastPathComponent)"
            },
            recordSaved: { saves.append($0); return [] })

        let first = await model.save()
        XCTAssertFalse(first)
        XCTAssertEqual(saves.last?.clips.map(\.exportAssetID), ["asset-clip-2.mp4"])

        model.addName("cork", origin: .typed, to: model.clipsToName[0].id)
        await photos.accept()
        model.saveFailureMessage = nil
        let second = await model.save()

        XCTAssertTrue(second)
        XCTAssertEqual(saves.last?.clips.map(\.exportAssetID), ["asset-clip-2.mp4", "asset-clip-6.mp4"])
        XCTAssertEqual(saves.last?.clips.first?.names.map(\.name), ["cork"])
    }

    func testTheSavesAnnouncementSpeaksWhatTheSaveEarned() async {
        var spokenAfter: [String] = []
        let model = nameClipsModel(
            [item(2, names: ["gainer"])],
            recordSaved: { _ in
                [EarnedAchievement(trick: "gainer", kind: .level, step: 1, earnedAt: Date())]
            },
            announceAfterScreenChange: { spokenAfter.append($0) })

        _ = await model.save()

        XCTAssertEqual(spokenAfter, ["Saved 1 clip to Photos. Earned Gainer, level 1"])
    }
}

/// A saved clip's video on its way to playing: an iCloud download shows its progress, a failure is
/// named and can be retried, and a video gone from Photos says so rather than loading forever.
@MainActor
final class LibraryClipPlaybackTests: XCTestCase {
    private let clip = LibraryClip(
        id: UUID(), sourceAssetID: "source", startTime: 0, endTime: 1, exportAssetID: "export", names: [],
        isMe: true, isAutoDetected: true, recordedAt: Date(), savedAt: Date())
    private let video = AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))

    private func playback(_ load: @escaping LoadLibraryClipVideo) -> LibraryClipPlayback {
        LibraryClipPlayback(mayAutoplayLoops: { false }, loadVideo: load)
    }

    /// Yields until `condition` holds, a bounded number of times so a regression fails instead of hanging.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    func testADownloadShowsItsProgressThenPlays() async {
        var release: CheckedContinuation<Void, Never>?
        let model = playback { [video] _, progress in
            progress(0.4)
            await withCheckedContinuation { release = $0 }
            return video
        }
        let loading = Task { await model.load(clip, autoplay: false) }
        await settle { model.phase == .downloading(0.4) && release != nil }
        XCTAssertEqual(model.phase, .downloading(0.4))
        XCTAssertNil(model.player)

        release?.resume()
        await loading.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.player)
    }

    func testAFailedDownloadIsNamedAndATryAgainStartsOver() async {
        var attempts = 0
        let model = playback { [video] _, _ in
            attempts += 1
            if attempts == 1 { throw VideoResolutionError.iCloudDownloadFailed(underlying: nil) }
            return video
        }

        await model.load(clip, autoplay: false)
        XCTAssertEqual(
            model.phase, .failed("Couldn't download this video from iCloud. Check your connection and try again."))
        XCTAssertNil(model.player)

        await model.load(clip, autoplay: false)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.player)
    }

    /// A progress report that arrives after the load failed doesn't turn the failure back into a download.
    func testALateProgressReportLeavesAFailureStanding() async {
        let model = playback { _, progress in
            progress(0.5)
            throw VideoResolutionError.iCloudDownloadFailed(underlying: nil)
        }
        await model.load(clip, autoplay: false)
        for _ in 0..<20 { await Task.yield() }
        guard case .failed = model.phase else { return XCTFail("phase is \(model.phase)") }
    }

    func testAVideoGoneFromPhotosSaysSo() async {
        let model = playback { _, _ in throw LibraryClipMediaError.notInPhotos }
        await model.load(clip, autoplay: false)
        XCTAssertEqual(model.phase, .notInPhotos)
    }

    func testACancelledLoadIsNotAFailure() async {
        let model = playback { _, _ in throw CancellationError() }
        await model.load(clip, autoplay: false)
        XCTAssertEqual(model.phase, .loading)
    }

    func testTheDownloadIsSpokenAsAPercentage() {
        XCTAssertEqual(ProfileAccessibility.downloadValue(0.424), "42 percent")
        XCTAssertEqual(ProfileAccessibility.downloadValue(1.2), "100 percent")
    }
}

final class LibraryClipThumbnailTests: XCTestCase {
    func testAFrameShowsAndPhotosIsNotAsked() {
        let frame = UIImage()
        var askedPhotos = false
        let still = LibraryClipThumbnail.still(loaded: frame, isInPhotos: { askedPhotos = true; return true }())
        XCTAssertEqual(still, .frame(frame))
        XCTAssertFalse(askedPhotos)
    }

    /// A video still in Photos whose frame didn't come is a failed fetch, not a blank tile.
    func testNoFrameForAVideoInPhotosIsUnavailable() {
        XCTAssertEqual(LibraryClipThumbnail.still(loaded: nil, isInPhotos: true), .unavailable)
    }

    func testNoFrameBecauseTheVideoLeftPhotosShowsItGone() {
        XCTAssertEqual(LibraryClipThumbnail.still(loaded: nil, isInPhotos: false), .notInPhotos)
    }
}
