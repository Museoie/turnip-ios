import AVFoundation
import XCTest
@testable import Turnip

/// Trashed trick-model proposals, kept as dismissed windows (`docs/PERSONALIZATION_DESIGN.md` §3):
/// what Name Clips' save hands the library, and how long the library keeps them.
@MainActor
final class DismissedWindowTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("library.json") }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-dismissed-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLibrary() -> ClipLibrary {
        ClipLibrary(fileURL: fileURL, vocabulary: { .seed }, announce: { _ in })
    }

    private func clip(_ start: TimeInterval, poseID: String?) -> LibrarySave.Clip {
        LibrarySave.Clip(
            id: UUID(), window: TrickWindow(startTime: start, endTime: start + 1.5), exportAssetID: "export",
            names: [], isMe: true, isAutoDetected: true, proposal: nil, poseID: poseID)
    }

    private func dismissed(_ start: Int, poseID: String = "pose-a", source: String = "source-1") -> DismissedWindow {
        DismissedWindow(sourceAssetID: source, poseID: poseID, startFrame: start, endFrame: start + 15)
    }

    private func save(
        _ clips: [LibrarySave.Clip], dismissed: [DismissedWindow], source: String = "source-1"
    ) -> LibrarySave {
        LibrarySave(sourceAssetID: source, sourceDuration: 30, clips: clips, dismissedWindows: dismissed)
    }

    // MARK: - The library

    func testATrashedProposalIsKeptWithItsPoseAcrossLaunches() {
        makeLibrary().record(save([clip(2, poseID: "pose-a")], dismissed: [dismissed(60)]), sourceRecordedAt: nil)
        XCTAssertEqual(makeLibrary().dismissedWindows, [dismissed(60)])
    }

    /// The record holds the source, the pose and two frame indices, and nothing else.
    func testTheRecordHoldsNothingButItsSourcePoseAndFrames() throws {
        makeLibrary().record(save([clip(2, poseID: "pose-a")], dismissed: [dismissed(60)]), sourceRecordedAt: nil)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let records = try XCTUnwrap(object["dismissedWindows"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(Set(records[0].keys), ["sourceAssetID", "poseID", "startFrame", "endFrame"])
    }

    /// Only on a pose the library keeps: one whose clips weren't saved, or whose pose couldn't be
    /// written, keeps nothing.
    func testATrashedProposalOnAPoseTheLibraryDoesntKeepIsDropped() {
        let library = makeLibrary()
        library.record(
            save([clip(2, poseID: "pose-a"), clip(5, poseID: nil)], dismissed: [dismissed(60, poseID: "pose-b")]),
            sourceRecordedAt: nil)
        XCTAssertEqual(library.dismissedWindows, [])
    }

    /// A retry after a partial failure hands the same trashed proposals over again.
    func testTheSameTrashedProposalIsKeptOnce() {
        let library = makeLibrary()
        library.record(save([clip(2, poseID: "pose-a")], dismissed: [dismissed(60)]), sourceRecordedAt: nil)
        library.record(
            save([clip(2, poseID: "pose-a")], dismissed: [dismissed(60), dismissed(90)]), sourceRecordedAt: nil)
        XCTAssertEqual(library.dismissedWindows, [dismissed(60), dismissed(90)])
    }

    /// Deleted with their pose, when its last clip leaves the library, and not before.
    func testTrashedProposalsGoWithTheirPose() throws {
        let library = makeLibrary()
        let first = clip(2, poseID: "pose-a"), second = clip(8, poseID: "pose-a"), other = clip(4, poseID: "pose-b")
        library.record(
            save([first, second, other], dismissed: [dismissed(60), dismissed(30, poseID: "pose-b")]),
            sourceRecordedAt: nil)

        library.delete(first.id)
        XCTAssertEqual(library.dismissedWindows.count, 2)
        library.delete(second.id)
        XCTAssertEqual(library.dismissedWindows, [dismissed(30, poseID: "pose-b")])
        XCTAssertEqual(makeLibrary().dismissedWindows, [dismissed(30, poseID: "pose-b")])
    }

    func testRemovingThemForgetsEveryTrashedProposal() {
        let library = makeLibrary()
        library.record(save([clip(2, poseID: "pose-a")], dismissed: [dismissed(60)]), sourceRecordedAt: nil)
        library.removeDismissedWindows()
        XCTAssertEqual(library.dismissedWindows, [])
        XCTAssertEqual(makeLibrary().dismissedWindows, [])
        XCTAssertEqual(makeLibrary().clips.count, 1)
    }

    /// A library written before it kept trashed proposals has no such key, and reads whole.
    func testALibraryFromBeforeTrashedProposalsWereKeptStillLoads() throws {
        makeLibrary().record(save([clip(2, poseID: "pose-a")], dismissed: [dismissed(60)]), sourceRecordedAt: nil)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        object["dismissedWindows"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let older = makeLibrary()
        XCTAssertEqual(older.clips.count, 1)
        XCTAssertEqual(older.dismissedWindows, [])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix("library-unreadable") })
    }

    // MARK: - Name Clips' save

    private func proposal(_ start: TimeInterval, personID: Int? = nil) -> ClipListItem {
        ClipListItem(
            window: TrickWindow(startTime: start, endTime: start + 1.5),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1), personID: personID, isAutoDetected: true,
            proposal: ModelProposal(modelVersion: "v1", suggestedNames: [], suggestionsWithheld: false),
            proposedFrames: Int(start * 10)..<Int(start * 10) + 15)
    }

    private func handAdded(_ start: TimeInterval) -> ClipListItem {
        ClipListItem(
            window: TrickWindow(startTime: start, endTime: start + 1.5),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1))
    }

    private func frames(_ count: Int) -> [PoseFrameResult] {
        PoseFixture.frames(hipXPositions: Array(repeating: 0.5, count: count))
    }

    private func nameClipsModel(
        _ items: [ClipListItem],
        recordSaved: @escaping RecordSavedClips,
        people: [PoseTrack] = [],
        windowEmbeddings: [WindowEmbeddings] = [],
        learnsFromClips: Bool = true,
        storePose: @escaping StoreSourcePose = { frames, _ in frames.isEmpty ? nil : "pose-\(frames.count)" },
        saveToPhotos: @escaping SaveOneClipToPhotos = { url, _ in "asset-\(url.lastPathComponent)" }
    ) -> ClipListViewModel {
        ClipListViewModel(
            items: items, poseFrames: frames(20), people: people, windowEmbeddings: windowEmbeddings,
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")), assetIdentifier: "source-1", duration: 30,
            exportClip: { spec, _, directory, _ in
                directory.appendingPathComponent("clip-\(Int(spec.window.startTime)).mp4")
            },
            saveToPhotos: saveToPhotos, recordSaved: recordSaved, storePose: storePose,
            makeDirectory: {
                FileManager.default.temporaryDirectory.appendingPathComponent("turnip-test-\(UUID().uuidString)")
            },
            settingsProvider: { TurnipSettings(learnsFromClips: learnsFromClips) }, announce: { _ in },
            announceAfterScreenChange: { _ in })
    }

    /// A proposal trashed on Name Clips reaches the library as the frames the model proposed, on
    /// the pose the save stored, however the tile was trimmed before it went.
    func testATrashedProposalIsSavedAsTheFramesTheModelProposed() async {
        var saves: [LibrarySave] = []
        let model = nameClipsModel([proposal(2), proposal(6)], recordSaved: { saves.append($0); return [] })
        let trashed = model.clipsToName[1]
        model.applyEditorResult(
            ClipEditorResult(
                window: TrickWindow(startTime: 6.2, endTime: 7), cropRect: trashed.cropRect, followCrop: nil),
            to: trashed.id)
        model.delete(trashed.id)

        _ = await model.save()

        XCTAssertEqual(saves.last?.dismissedWindows, [
            DismissedWindow(sourceAssetID: "source-1", poseID: "pose-20", startFrame: 60, endFrame: 75)
        ])
    }

    /// Clips added with "+", and clips the heuristic proposed, are no proposal of the model's.
    func testATrashedClipTheModelDidntProposeLeavesNothing() async {
        var saves: [LibrarySave] = []
        let model = nameClipsModel([proposal(2), handAdded(6)], recordSaved: { saves.append($0); return [] })
        model.delete(model.clipsToName[1].id)

        _ = await model.save()

        XCTAssertEqual(saves.last?.dismissedWindows, [])
    }

    func testWithLearnFromMyClipsOffNothingTrashedIsKept() async {
        var saves: [LibrarySave] = []
        let model = nameClipsModel(
            [proposal(2), proposal(6)], recordSaved: { saves.append($0); return [] }, learnsFromClips: false)
        model.delete(model.clipsToName[1].id)

        _ = await model.save()

        XCTAssertEqual(saves.last?.dismissedWindows, [])
    }

    /// Following everyone, a trashed proposal goes with its own person's pose, and only when that
    /// person has a saved clip for the library to keep their pose by.
    func testFollowingEveryoneATrashedProposalGoesWithItsOwnPersonsPose() async {
        var saves: [LibrarySave] = []
        let model = nameClipsModel(
            [proposal(2, personID: 0), proposal(4, personID: 0), proposal(6, personID: 3)],
            recordSaved: { saves.append($0); return [] },
            people: [PoseTrack(id: 0, frames: frames(5)), PoseTrack(id: 3, frames: frames(7))])
        model.delete(model.clipsToName[1].id)
        model.delete(model.clipsToName[1].id)

        _ = await model.save()

        XCTAssertEqual(saves.last?.dismissedWindows.map(\.poseID), ["pose-5"])
        XCTAssertEqual(saves.last?.dismissedWindows.map(\.startFrame), [40])
    }

    /// Backing out of Name Clips saves nothing, so a trashed proposal goes nowhere; and a save with
    /// no clip in Photos writes no source, so it keeps none either.
    func testASaveWithNothingInPhotosKeepsNoTrashedProposal() async {
        var saves: [LibrarySave] = []
        let model = nameClipsModel(
            [proposal(2), proposal(6)], recordSaved: { saves.append($0); return [] },
            saveToPhotos: { _, _ in throw ClipSaveError.photosSaveFailed(reason: "denied") })
        model.delete(model.clipsToName[1].id)

        _ = await model.save()

        XCTAssertEqual(saves.count, 0)
    }

    /// A clip already in Photos stays a saved clip, whatever the list does with it afterward.
    func testAProposalTrashedAfterItWasSavedIsNoDismissal() async {
        actor Photos {
            var isRejecting = true
            func accept() { isRejecting = false }
        }
        var saves: [LibrarySave] = []
        let photos = Photos()
        let model = nameClipsModel(
            [proposal(2), proposal(6)], recordSaved: { saves.append($0); return [] },
            saveToPhotos: { url, _ in
                if url.lastPathComponent == "clip-6.mp4", await photos.isRejecting {
                    throw ClipSaveError.photosSaveFailed(reason: "denied")
                }
                return "asset-\(url.lastPathComponent)"
            })
        _ = await model.save()
        model.delete(model.clipsToName[0].id)
        await photos.accept()
        model.saveFailureMessage = nil

        _ = await model.save()

        XCTAssertEqual(saves.last?.dismissedWindows, [])
    }

    /// The save hands the personal layer each stored pose's run, by the pose's ID.
    func testASaveCarriesEachStoredPosesRun() async {
        var saves: [LibrarySave] = []
        let athlete = KeepFixture.run(scores: [0.4], axes: [0], personID: 0)
        let bystander = KeepFixture.run(scores: [0.6], axes: [1], personID: 3)
        let model = nameClipsModel(
            [proposal(2, personID: 0)], recordSaved: { saves.append($0); return [] },
            people: [PoseTrack(id: 0, frames: frames(5)), PoseTrack(id: 3, frames: frames(7))],
            windowEmbeddings: [athlete, bystander])

        _ = await model.save()

        XCTAssertEqual(saves.last?.runs, ["pose-5": athlete])
    }
}
