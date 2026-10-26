import AVFoundation
import XCTest
@testable import Turnip

@MainActor
final class NameClipsTests: XCTestCase {
    private let fullFrame = NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1)

    private func item(_ start: TimeInterval, person: Int? = nil, names: [ClipName] = []) -> ClipListItem {
        ClipListItem(
            window: TrickWindow(startTime: start, endTime: start + 1), cropRect: fullFrame, personID: person,
            names: names, isAutoDetected: true)
    }

    private func viewModel(_ items: [ClipListItem], poseFrames: [PoseFrameResult] = []) -> ClipListViewModel {
        ClipListViewModel(
            items: items, poseFrames: poseFrames, asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")),
            assetIdentifier: "asset-1", duration: 10,
            exportClip: { _, _, _, _ in URL(fileURLWithPath: "/tmp/fake.mp4") },
            saveToPhotos: { _, _ in }, deleteOriginalAsset: { _ in },
            makeDirectory: {
                FileManager.default.temporaryDirectory.appendingPathComponent("turnip-test-\(UUID().uuidString)")
            },
            settingsProvider: { TurnipSettings() }, announce: { _ in }, announceAfterScreenChange: { _ in })
    }

    private func names(_ model: ClipListViewModel, _ index: Int) -> [ClipName] {
        model.clipsToName[index].names
    }

    func testNamesAreTrimmedAndKeptOncePerClipInAnyCase() {
        let model = viewModel([item(1)])
        let id = model.clipsToName[0].id
        model.addName("  Gainer ", origin: .typed, to: id)
        model.addName("gainer", origin: .vocabulary, to: id)
        model.addName("   ", origin: .typed, to: id)
        model.addName("cork", origin: .vocabulary, to: id)
        XCTAssertEqual(names(model, 0), [
            ClipName(name: "Gainer", origin: .typed), ClipName(name: "cork", origin: .vocabulary)
        ])
    }

    /// The contribute toggle needs a name, and removing the last one turns it back off.
    func testContributingNeedsANameAndLosesItWithTheLastOne() {
        let model = viewModel([item(1)])
        let id = model.clipsToName[0].id
        model.setContributes(true, for: id)
        XCTAssertFalse(model.clipsToName[0].contributes)
        model.addName("cork", origin: .typed, to: id)
        model.setContributes(true, for: id)
        XCTAssertTrue(model.clipsToName[0].contributes)
        model.removeName(ClipName(name: "cork", origin: .typed), from: id)
        XCTAssertFalse(model.clipsToName[0].contributes)
    }

    /// "Did you mean" puts the vocabulary's spelling where the typed name was, as a pick.
    func testACorrectionReplacesTheTypedNameInPlace() {
        let typed = ClipName(name: "gainr", origin: .typed)
        let model = viewModel([item(1, names: [ClipName(name: "hook", origin: .typed), typed])])
        model.replaceName(typed, with: "gainer", in: model.clipsToName[0].id)
        XCTAssertEqual(names(model, 0), [
            ClipName(name: "hook", origin: .typed), ClipName(name: "gainer", origin: .vocabulary)
        ])
    }

    /// The first clip's choice carries to the person's later clips that still read as it did; a
    /// clip already set apart, and another person's clips, keep theirs.
    func testWhoIsInItCarriesFromAPersonsFirstClip() {
        let model = viewModel([item(1, person: 1), item(3, person: 1), item(5, person: 1), item(7, person: 2)])
        let clips = model.clipsToName
        model.setIsMe(false, for: clips[1].id)
        XCTAssertEqual(model.clipsToName.map(\.isMe), [true, false, true, true])

        model.setIsMe(false, for: clips[0].id)
        XCTAssertEqual(model.clipsToName.map(\.isMe), [false, false, false, true])
    }

    func testNamesUsedOnTheVideoComeOnceInTheOrderGiven() {
        let model = viewModel([
            item(1, names: [ClipName(name: "cork", origin: .typed), ClipName(name: "hook", origin: .typed)]),
            item(3, names: [ClipName(name: "Cork", origin: .typed), ClipName(name: "gainer", origin: .typed)])
        ])
        XCTAssertEqual(model.namesUsedOnVideo, ["cork", "hook", "gainer"])
    }

    /// An editor commit keeps the names; a retrim makes the window the user's, not detection's.
    func testEditorCommitsKeepNamesAndARetrimClearsAutoDetected() {
        let model = viewModel([item(1, names: [ClipName(name: "cork", origin: .typed)])])
        let clip = model.clipsToName[0]
        let unchanged = ClipEditorResult(
            window: clip.window, cropRect: clip.cropRect, cropAdjustment: clip.cropAdjustment,
            framingMode: clip.framingMode, followCrop: clip.followCrop)
        model.applyEditorResult(unchanged, to: clip.id)
        XCTAssertTrue(model.clipsToName[0].isAutoDetected)
        XCTAssertEqual(names(model, 0), [ClipName(name: "cork", origin: .typed)])

        let retrimmed = ClipEditorResult(
            window: TrickWindow(startTime: 1.2, endTime: 2), cropRect: clip.cropRect,
            cropAdjustment: clip.cropAdjustment, framingMode: clip.framingMode, followCrop: clip.followCrop)
        model.applyEditorResult(retrimmed, to: clip.id)
        XCTAssertFalse(model.clipsToName[0].isAutoDetected)
        XCTAssertEqual(names(model, 0), [ClipName(name: "cork", origin: .typed)])
    }

    // MARK: - Contribution plan

    private static func posed(from start: TimeInterval, to end: TimeInterval) -> [PoseFrameResult] {
        stride(from: start, through: end, by: 0.1).enumerated().map { index, time in
            PoseFrameResult(
                frameIndex: index, timestamp: time,
                keypoints: PoseKeypoint.names.map { PoseKeypoint(name: $0, y: 0.5, x: 0.5, confidence: 0.9) })
        }
    }

    /// Only saved, toggled, named clips go; the sequence is the first clip's person's, and another
    /// person's clip stays behind.
    func testPlanSendsTheFirstPersonsSavedToggledClips() async {
        let named = [ClipName(name: "cork", origin: .typed)]
        var first = item(1, person: 1, names: named)
        first.contributes = true
        var second = item(4, person: 2, names: named)
        second.contributes = true
        let untoggled = item(6, person: 1, names: named)
        let model = viewModel([first, second, untoggled], poseFrames: Self.posed(from: 0, to: 10))
        _ = await model.save()

        let plan = model.contributionPlan()
        XCTAssertEqual(plan.clips.map(\.item.id), [first.id, second.id])
        XCTAssertEqual(plan.clips.map(\.status), [.ready, .otherPerson])
        XCTAssertEqual(plan.source?.clips.map(\.clipID), [first.id])
        XCTAssertEqual(plan.source?.videoID, VideoIdentity.videoID(forAssetIdentifier: "asset-1"))
    }

    func testPlanRefusesAVideoPoseTrackingMostlyLost() async {
        var clip = item(1, names: [ClipName(name: "cork", origin: .typed)])
        clip.contributes = true
        // Pose only at the very start and end: the window from 1 s to 2 s is all gaps.
        let model = viewModel([clip], poseFrames: Self.posed(from: 0, to: 0.3) + Self.posed(from: 9, to: 10))
        _ = await model.save()

        let plan = model.contributionPlan()
        XCTAssertEqual(plan.quality, .unusable)
        XCTAssertNil(plan.source)
    }

    // MARK: - Vocabulary

    func testVocabularyResolvesSpellingsAndSuggestsCorrections() {
        let vocabulary = TrickVocabulary.seed
        XCTAssertEqual(vocabulary.canonicalName(for: " CorkScrew "), "cork")
        XCTAssertNil(vocabulary.canonicalName(for: "butterfly twist"))
        XCTAssertEqual(vocabulary.names(matching: "co"), ["cork", "scoot"])
        XCTAssertEqual(vocabulary.names(matching: ""), ["cartfull", "cork", "gainer", "hook", "scoot"])
        XCTAssertEqual(vocabulary.suggestedCorrection(for: "gainr"), "gainer")
        XCTAssertEqual(vocabulary.suggestedCorrection(for: "corkscrew"), "cork")
        XCTAssertNil(vocabulary.suggestedCorrection(for: "cork"))
        XCTAssertNil(vocabulary.suggestedCorrection(for: "bok"), "two edits from hook is too far for three letters")
    }

    /// The newest vocabulary wins, and a fetched one survives a relaunch.
    func testVocabularyStoreAdoptsOnlyANewerFetchAndCachesIt() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let newer = #"{"taxonomy_version":4,"vocabulary":[{"canonical":"btwist","aliases":["butterfly twist"]}]}"#
        let client = FarmClient(baseURL: URL(string: "https://farm.test")!) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(newer.utf8), response)
        }
        let store = VocabularyStore(client: client, cacheURL: cache)
        XCTAssertEqual(store.current, .seed)
        await store.refreshIfStale()
        XCTAssertEqual(store.current.taxonomyVersion, 4)
        XCTAssertEqual(VocabularyStore(client: nil, cacheURL: cache).current.taxonomyVersion, 4)
    }
}
