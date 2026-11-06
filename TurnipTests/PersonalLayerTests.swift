import AVFoundation
import XCTest
@testable import Turnip

/// Stands in for the trick model: every pose comes out as one row along the axis `axisOf` gives it,
/// and it remembers which poses it ran over.
private final class FakeModel: PoseEmbedder, @unchecked Sendable {
    let version: String
    let hasEmbeddings: Bool
    private let lock = NSLock()
    private var ranPoses: [ContributionPose] = []
    private let failing: Set<Float>
    private let heldRun: Int?
    private let release = DispatchSemaphore(value: 0)

    /// `heldRun` is the run, counting from 1, that waits inside the model until `releaseHeldRun()`.
    init(version: String = "v1", hasEmbeddings: Bool = true, failing: Set<Float> = [], heldRun: Int? = nil) {
        self.version = version
        self.hasEmbeddings = hasEmbeddings
        self.failing = failing
        self.heldRun = heldRun
    }

    var runCount: Int { lock.withLock { ranPoses.count } }

    func releaseHeldRun() { release.signal() }

    func windowEmbeddings(over pose: ContributionPose) throws -> WindowEmbeddings? {
        let run = lock.withLock { () -> Int in
            ranPoses.append(pose)
            return ranPoses.count
        }
        if run == heldRun { release.wait() }
        let first = pose.slots.first.flatMap { $0 }?.first ?? 0
        if failing.contains(first) { throw TrickModelError.unexpectedOutput }
        return WindowEmbeddings(
            personID: nil, modelVersion: version,
            descriptor: TrickModelDescriptor(classes: ["background", "cork"], windowFrames: 10, windowStride: 5),
            rows: [PersonalFixture.axis(0), PersonalFixture.axis(0), PersonalFixture.axis(0)],
            probabilities: [[0, 1], [0, 1], [0, 1]])
    }
}

@MainActor
final class PersonalLayerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var library: ClipLibrary!
    private var settings: TurnipSettingsStore!
    private var scheduled = 0
    private var cancelled = 0

    private var cacheURL: URL { directory.appendingPathComponent("cache/personal-cache.json") }
    private var cacheStore: PersonalCacheStore { PersonalCacheStore(fileURL: cacheURL) }
    private var libraryURL: URL { directory.appendingPathComponent("library.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-personal-test-\(UUID().uuidString)", isDirectory: true)
        suiteName = "PersonalLayerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = TurnipSettingsStore(defaults: defaults)
        library = ClipLibrary(fileURL: libraryURL, vocabulary: { PersonalFixture.vocabulary }, announce: { _ in })
        scheduled = 0
        cancelled = 0
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// `activeVersion` is what the store reports after that many loads; left out, it is the model's
    /// own.
    private func makeLayer(
        model: PoseEmbedder? = FakeModel(), activeVersion: (@Sendable (_ loads: Int) -> String?)? = nil,
        isTooHot: @escaping @Sendable () -> Bool = { false },
        namingSettles: DispatchQueue.SchedulerTimeType.Stride = .seconds(600)
    ) -> PersonalLayer {
        let counts = Counts()
        self.counts = counts
        return PersonalLayer(
            library: library, settings: settings, vocabulary: { PersonalFixture.vocabulary }, cacheStore: cacheStore,
            activeVersion: { activeVersion.map { $0(counts.loadCount) } ?? model?.version },
            loadModel: {
                counts.addLoad()
                return model
            },
            scheduler: PersonalRebuildScheduler(schedule: { counts.addScheduled() }, cancel: { counts.addCancelled() }),
            isTooHot: isTooHot, namingSettles: namingSettles)
    }

    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var scheduled = 0
        private var cancelled = 0
        private var loads = 0
        var scheduledCount: Int { lock.withLock { scheduled } }
        var cancelledCount: Int { lock.withLock { cancelled } }
        var loadCount: Int { lock.withLock { loads } }
        func addScheduled() { lock.withLock { scheduled += 1 } }
        func addCancelled() { lock.withLock { cancelled += 1 } }
        func addLoad() { lock.withLock { loads += 1 } }
    }

    private var counts = Counts()

    private func embedding(_ version: String = "v1", axis: Int = 0, central: [String] = []) -> ClipEmbedding {
        ClipEmbedding(modelVersion: version, vector: PersonalFixture.axis(axis), centralNames: central)
    }

    /// A save of one clip on its own video, so nothing about it is in tier 1 for the others.
    private func save(
        name: String, embedding: ClipEmbedding?, poseID: String? = nil, id: UUID = UUID(), layer: PersonalLayer?
    ) {
        let saved = LibrarySave(
            sourceAssetID: UUID().uuidString, sourceDuration: 10,
            clips: [
                LibrarySave.Clip(
                    id: id, window: TrickWindow(startTime: 0, endTime: 1.5), exportAssetID: "export",
                    names: [ClipName(name: name, origin: .typed)], isMe: true, isAutoDetected: true, proposal: nil,
                    poseID: poseID, embedding: embedding)
            ])
        library.record(saved, sourceRecordedAt: Date())
        layer?.record(saved)
    }

    private func saveFlashKicks(_ count: Int, layer: PersonalLayer) {
        for _ in 0..<count {
            save(name: "flash kick", embedding: embedding(central: ["cork"]), layer: layer)
        }
    }

    private func storedPose(_ value: Float) throws -> String {
        try XCTUnwrap(library.poseStore.store(
            ContributionPose(sampleRate: 10, slots: [Array(repeating: value, count: 51), nil])))
    }

    // MARK: - Falling back to the central model

    func testWithoutAModelThereIsNoRanking() async {
        let layer = makeLayer(model: nil)
        await layer.start()
        saveFlashKicks(12, layer: layer)
        await layer.refresh().value
        XCTAssertNil(layer.ranking)
    }

    /// Only the load can show a model has no embeddings, so its rebuild runs nothing and ends, and
    /// the layer stops asking for one.
    func testAModelWithoutEmbeddingsHasNoRanking() async throws {
        for index in 0..<12 {
            save(name: "flash kick", embedding: nil, poseID: try storedPose(Float(index + 1) / 20), layer: nil)
        }
        let model = FakeModel(hasEmbeddings: false)
        let layer = makeLayer(model: model)

        let finished = await layer.rebuild()
        await layer.settle()

        XCTAssertTrue(finished)
        XCTAssertEqual(model.runCount, 0)
        XCTAssertNil(layer.ranking)
        XCTAssertEqual(cacheStore.load()?.isRebuilt, true)
        let scheduledBefore = counts.scheduledCount
        await layer.start()
        await layer.settle()
        XCTAssertEqual(counts.scheduledCount, scheduledBefore)
    }

    /// The launch's one load belongs to the first analysis, so a model staged moments after launch
    /// still reaches it.
    func testComingForwardNeverLoadsTheModel() async throws {
        let first = makeLayer()
        await first.start()
        saveFlashKicks(10, layer: first)
        await first.refresh().value
        await first.settle()
        XCTAssertNotNil(first.ranking)
        XCTAssertEqual(counts.loadCount, 0)

        save(name: "flash kick", embedding: nil, poseID: try storedPose(0.2), layer: nil)
        let evicted = makeLayer(model: FakeModel(version: "v2"))
        await evicted.start()
        await evicted.settle()
        XCTAssertEqual(counts.loadCount, 0, "even when the cache has to start again")
    }

    func testTheToggleBackOnNeverLoadsTheModel() async throws {
        save(name: "flash kick", embedding: nil, poseID: try storedPose(0.2), layer: nil)
        let layer = makeLayer()
        settings.learnsFromClips = false
        for _ in 0..<200 where counts.cancelledCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        settings.learnsFromClips = true
        for _ in 0..<200 where counts.scheduledCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await layer.settle()
        XCTAssertGreaterThan(counts.scheduledCount, 0)
        XCTAssertEqual(counts.loadCount, 0)
    }

    func testARebuildWithNothingToDoNeverLoadsTheModel() async {
        let layer = makeLayer()
        let finished = await layer.rebuild()
        XCTAssertTrue(finished)
        XCTAssertEqual(counts.loadCount, 0)
    }

    func testTooFewClipsHaveNoRanking() async {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(9, layer: layer)
        await layer.refresh().value
        XCTAssertNil(layer.ranking)
    }

    func testAGateThatFailsLeavesNoRanking() async {
        let layer = makeLayer()
        await layer.start()
        for _ in 0..<12 {
            save(name: "cork", embedding: embedding(central: ["cork"]), layer: layer)
        }
        await layer.refresh().value
        XCTAssertNil(layer.ranking)
    }

    // MARK: - After each save

    func testRankingTurnsOnOnceTheSavesBeatTheCentralModel() async throws {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value

        let ranking = try XCTUnwrap(layer.ranking)
        XCTAssertEqual(ranking.modelVersion, "v1")
        XCTAssertEqual(ranking.prototypes.map(\.name), ["flash kick"])
    }

    func testANewClipGetsTheNearestNameAfterTheVideosOwn() async {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value

        let suggestions = layer.suggestions(for: embedding(), proposal: nil, used: ["hook"], given: [])
        XCTAssertEqual(suggestions, PersonalSuggestions(used: ["hook"], nearest: ["flash kick"]))
    }

    /// Withheld on a blind clip, down to tier 1's order (`MODEL_CONTRACT.md` §3.3 step 5).
    func testABlindClipGetsNoRanking() async {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value
        let blind = ModelProposal(modelVersion: "v1", suggestedNames: [], suggestionsWithheld: true)

        let suggestions = layer.suggestions(
            for: embedding(), proposal: blind, used: ["hook", "flash kick"], given: [])

        XCTAssertEqual(suggestions, PersonalSuggestions(used: ["hook", "flash kick"]))
    }

    func testAModelProposedClipThatIsntBlindGetsRanking() async {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value
        let proposal = ModelProposal(modelVersion: "v1", suggestedNames: [], suggestionsWithheld: false)

        let suggestions = layer.suggestions(for: embedding(), proposal: proposal, used: [], given: [])

        XCTAssertEqual(suggestions.nearest, ["flash kick"])
    }

    func testAClipWithoutAnEmbeddingGetsNoRanking() async {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value
        XCTAssertEqual(
            layer.suggestions(for: nil, proposal: nil, used: ["hook"], given: []), PersonalSuggestions(used: ["hook"]))
    }

    /// Two versions' embeddings live in different spaces.
    func testAnEmbeddingFromAnotherVersionGetsNoRanking() async {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value
        XCTAssertEqual(
            layer.suggestions(for: embedding("v2"), proposal: nil, used: [], given: []), PersonalSuggestions(used: []))
    }

    func testASavedClipReadsItsEmbeddingFromTheCache() async throws {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(11, layer: layer)
        await layer.refresh().value
        let clip = try XCTUnwrap(library.clips.first)

        XCTAssertEqual(layer.suggestions(forSaved: clip, used: []).nearest, [])
        library.removeName(clip.names[0], from: clip.id)
        await layer.refresh().value
        let renamed = try XCTUnwrap(library.clip(clip.id))
        XCTAssertEqual(layer.suggestions(forSaved: renamed, used: []).nearest, ["flash kick"])
    }

    func testASavedBlindClipGetsNoRanking() async throws {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value
        var clip = try XCTUnwrap(library.clips.first)
        clip.names = []
        clip.proposal = ModelProposal(modelVersion: "v1", suggestedNames: [], suggestionsWithheld: true)
        XCTAssertEqual(layer.suggestions(forSaved: clip, used: ["hook"]), PersonalSuggestions(used: ["hook"]))
    }

    /// Names change after a save, and nothing but the library knows.
    func testANameGivenOnTheProfileReachesThePrototypes() async throws {
        let layer = makeLayer(namingSettles: .milliseconds(1))
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value
        for clip in library.clips.prefix(4) {
            library.addName("twist", origin: .typed, to: clip.id)
        }
        for _ in 0..<200 where layer.ranking?.prototypes.count != 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(Set(layer.ranking?.prototypes.map(\.key) ?? []), ["flash kick", "twist"])
    }

    /// An embedding made under one version is no use to a layer built on another.
    func testASavesEmbeddingFromAnotherVersionIsNotKept() async {
        let layer = makeLayer()
        await layer.start()
        for _ in 0..<12 {
            save(name: "flash kick", embedding: embedding("v0"), layer: layer)
        }
        await layer.refresh().value
        XCTAssertNil(layer.ranking)
    }

    func testAClipGoneFromTheLibraryLeavesTheCache() async throws {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(3, layer: layer)
        await layer.refresh().value
        library.delete(try XCTUnwrap(library.clips.first?.id))
        await layer.refresh().value
        await layer.settle()
        XCTAssertEqual(cacheStore.load()?.clips.count, 2)
    }

    // MARK: - What it stores

    func testTheCacheIsReadBackByTheNextLaunch() async throws {
        let first = makeLayer()
        await first.start()
        saveFlashKicks(10, layer: first)
        await first.refresh().value
        await first.settle()

        let second = makeLayer()
        await second.start()
        await second.refresh().value

        XCTAssertNotNil(second.ranking)
    }

    /// A save writes nothing of the embedding into the library, which is in device backups.
    func testEmbeddingsStayOutOfTheLibraryFile() async throws {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(3, layer: layer)
        await layer.settle()
        let file = try String(contentsOf: libraryURL, encoding: .utf8)
        XCTAssertFalse(file.contains("vector"))
        XCTAssertFalse(file.contains("embedding"))
    }

    // MARK: - On a model update

    func testAnotherVersionDropsTheOldCacheAndTurnsTheLayerOffUntilItRebuilds() async throws {
        let poseID = try storedPose(0.2)
        let first = makeLayer()
        await first.start()
        for _ in 0..<10 {
            save(name: "flash kick", embedding: embedding(central: ["cork"]), poseID: poseID, layer: first)
        }
        await first.refresh().value
        await first.settle()
        XCTAssertNotNil(first.ranking)

        let updated = makeLayer(model: FakeModel(version: "v2"))
        await updated.start()
        await updated.settle()

        XCTAssertNil(updated.ranking)
        XCTAssertEqual(cacheStore.load()?.modelVersion, "v2")
        XCTAssertEqual(cacheStore.load()?.clips, [:])
        XCTAssertGreaterThan(counts.scheduledCount, 0)
    }

    func testTheRebuildRunsTheNewModelOverEachStoredPoseOnce() async throws {
        let poseIDs = try (0..<10).map { try storedPose(Float($0 + 1) / 20) }
        for poseID in poseIDs {
            save(name: "flash kick", embedding: nil, poseID: poseID, layer: nil)
        }
        let model = FakeModel()
        let layer = makeLayer(model: model)

        let finished = await layer.rebuild()

        XCTAssertTrue(finished)
        XCTAssertEqual(model.runCount, 10)
        XCTAssertNotNil(layer.ranking, "the rebuild ends by turning the layer back on through the gate")
        XCTAssertGreaterThan(counts.cancelledCount, 0, "and leaves no second run queued")
    }

    /// The rebuild's load tries a staged model first, and the store makes it active, so the run that
    /// began on the old version carries on under the new one.
    func testTheRebuildFollowsTheModelItsLoadActivates() async throws {
        for index in 0..<10 {
            save(name: "flash kick", embedding: nil, poseID: try storedPose(Float(index + 1) / 20), layer: nil)
        }
        let staged = FakeModel(version: "v2")
        let layer = makeLayer(model: staged, activeVersion: { loads in loads == 0 ? "v1" : "v2" })

        let finished = await layer.rebuild()
        await layer.settle()

        XCTAssertTrue(finished)
        XCTAssertEqual(staged.runCount, 10)
        XCTAssertEqual(cacheStore.load()?.modelVersion, "v2")
        XCTAssertEqual(cacheStore.load()?.isRebuilt, true)
        XCTAssertNotNil(layer.ranking)
    }

    /// Two clips of a person share a pose, which runs once.
    func testClipsThatShareAPoseRunItOnce() async throws {
        let poseID = try storedPose(0.2)
        save(name: "flash kick", embedding: nil, poseID: poseID, layer: nil)
        save(name: "flash kick", embedding: nil, poseID: poseID, layer: nil)
        let model = FakeModel()

        _ = await makeLayer(model: model).rebuild()

        XCTAssertEqual(model.runCount, 1)
    }

    func testTheRebuildIsNeverStartedWithoutAModel() async throws {
        save(name: "flash kick", embedding: nil, poseID: try storedPose(0.2), layer: nil)
        let layer = makeLayer(model: nil)
        await layer.start()
        await layer.settle()
        XCTAssertEqual(counts.scheduledCount, 0)
    }

    func testAnInterruptedRebuildPicksUpWhereItStopped() async throws {
        for index in 0..<4 {
            save(name: "flash kick", embedding: nil, poseID: try storedPose(Float(index + 1) / 10), layer: nil)
        }
        let model = FakeModel()
        let layer = makeLayer(model: model)
        let stopsAfterTwo = StopAfter(2)

        let first = await layer.rebuild { stopsAfterTwo.shouldStop() }
        XCTAssertFalse(first)
        XCTAssertEqual(model.runCount, 2)
        XCTAssertNil(layer.ranking, "off until it has been through every pose")
        XCTAssertGreaterThan(counts.scheduledCount, 0, "it asks to run again")
        await layer.settle()

        let relaunched = makeLayer(model: model)
        let second = await relaunched.rebuild()

        XCTAssertTrue(second)
        XCTAssertEqual(model.runCount, 4)
    }

    private final class StopAfter: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(_ count: Int) { remaining = count }
        func shouldStop() -> Bool {
            lock.withLock {
                defer { remaining -= 1 }
                return remaining <= 0
            }
        }
    }

    func testTheRebuildWaitsOutAHotDevice() async throws {
        save(name: "flash kick", embedding: nil, poseID: try storedPose(0.2), layer: nil)
        let model = FakeModel()
        let layer = makeLayer(model: model, isTooHot: { true })

        let finished = await layer.rebuild()

        XCTAssertFalse(finished)
        XCTAssertEqual(model.runCount, 0)
        XCTAssertGreaterThan(counts.scheduledCount, 0)
    }

    func testThermalStatesSeriousAndAboveAreTooHot() {
        XCTAssertEqual(LivePoseThermalPolicy.response(to: .fair), .normal)
        XCTAssertNotEqual(LivePoseThermalPolicy.response(to: .serious), .normal)
        XCTAssertNotEqual(LivePoseThermalPolicy.response(to: .critical), .normal)
    }

    /// One unreadable pose can't hold the layer off for good.
    func testAPoseThatCantBeReadOrRunIsPassedOver() async throws {
        let unreadable = try storedPose(0.1)
        library.poseStore.remove(unreadable)
        save(name: "flash kick", embedding: nil, poseID: unreadable, layer: nil)
        save(name: "flash kick", embedding: nil, poseID: try storedPose(0.3), layer: nil)
        for index in 0..<10 {
            save(name: "flash kick", embedding: nil, poseID: try storedPose(Float(index + 7) / 20), layer: nil)
        }
        let model = FakeModel(failing: [0.3])
        let layer = makeLayer(model: model)

        let finished = await layer.rebuild()

        XCTAssertTrue(finished)
        XCTAssertNotNil(layer.ranking)
        await layer.settle()
        XCTAssertEqual(cacheStore.load()?.clips.count, 10)
    }

    /// A clip saved before pose was kept has nothing to rebuild from, so it is simply absent.
    func testAClipWithNoPoseIsLeftOutOfTheRebuild() async throws {
        save(name: "flash kick", embedding: nil, poseID: nil, layer: nil)
        save(name: "flash kick", embedding: nil, poseID: try storedPose(0.2), layer: nil)
        let layer = makeLayer()
        _ = await layer.rebuild()
        await layer.settle()
        XCTAssertEqual(cacheStore.load()?.clips.count, 1)
    }

    /// iOS evicted `Caches/`: the library still holds what it takes to make it again.
    func testAnEvictedCacheIsRebuiltFromTheLibrary() async throws {
        let poseID = try storedPose(0.2)
        let first = makeLayer()
        await first.start()
        for _ in 0..<10 {
            save(name: "flash kick", embedding: embedding(central: ["cork"]), poseID: poseID, layer: first)
        }
        await first.refresh().value
        await first.settle()
        cacheStore.delete()

        let relaunched = makeLayer()
        await relaunched.start()
        await relaunched.settle()

        XCTAssertNil(relaunched.ranking)
        XCTAssertGreaterThan(counts.scheduledCount, 0)
    }

    func testALibraryWithNoPoseHasNothingToRebuild() async {
        let layer = makeLayer()
        await layer.start()
        await layer.settle()
        XCTAssertEqual(counts.scheduledCount, 0)
        XCTAssertEqual(cacheStore.load()?.isRebuilt, true)
    }

    // MARK: - The toggle

    func testTurningTheToggleOffDeletesTheCacheAndTheRanking() async throws {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value
        await layer.settle()
        XCTAssertNotNil(layer.ranking)

        settings.learnsFromClips = false
        for _ in 0..<200 where layer.ranking != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await layer.settle()

        XCTAssertNil(layer.ranking)
        XCTAssertNil(cacheStore.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertGreaterThan(counts.cancelledCount, 0)
    }

    /// Off and straight back on can't bring back what off deleted.
    func testTurningTheToggleOffAndStraightBackOnLeavesTheCacheDeleted() async throws {
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(10, layer: layer)
        await layer.refresh().value
        await layer.settle()

        settings.learnsFromClips = false
        settings.learnsFromClips = true
        for _ in 0..<200 where cacheStore.load()?.clips.isEmpty != true {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await layer.settle()

        XCTAssertEqual(cacheStore.load()?.clips, [:])
        XCTAssertNil(layer.ranking)
    }

    func testWithTheToggleOffASaveKeepsNothing() async {
        settings.learnsFromClips = false
        let layer = makeLayer()
        await layer.start()
        saveFlashKicks(12, layer: layer)
        await layer.refresh().value
        await layer.settle()
        XCTAssertNil(layer.ranking)
        XCTAssertNil(cacheStore.load())
    }

    func testTurningTheToggleBackOnRebuildsFromTheLibrary() async throws {
        let layer = makeLayer()
        await layer.start()
        save(name: "flash kick", embedding: embedding(), poseID: try storedPose(0.2), layer: layer)
        await layer.settle()
        settings.learnsFromClips = false
        for _ in 0..<200 where counts.cancelledCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let scheduledBefore = counts.scheduledCount

        settings.learnsFromClips = true
        for _ in 0..<200 where counts.scheduledCount == scheduledBefore {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertGreaterThan(counts.scheduledCount, scheduledBefore)
    }

    func testTheRebuildStopsWhenTheToggleGoesOff() async throws {
        for index in 0..<3 {
            save(name: "flash kick", embedding: nil, poseID: try storedPose(Float(index + 1) / 10), layer: nil)
        }
        let layer = makeLayer()
        settings.learnsFromClips = false
        for _ in 0..<20 { await Task.yield() }
        let finished = await layer.rebuild()
        await layer.settle()
        XCTAssertTrue(finished, "nothing to do while it's off")
        XCTAssertNil(cacheStore.load())
    }

    /// Off and back on mid-run starts the cache over, so the pose done before the flip runs again,
    /// and the rebuild doesn't call itself finished with it missing.
    func testTheToggleOffAndBackOnDuringARebuildRunsEveryPoseAgain() async throws {
        for index in 0..<3 {
            save(name: "flash kick", embedding: nil, poseID: try storedPose(Float(index + 1) / 10), layer: nil)
        }
        let model = FakeModel(heldRun: 2)
        let layer = makeLayer(model: model)
        let rebuild = Task { await layer.rebuild() }
        for _ in 0..<400 where model.runCount < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.runCount, 2)

        settings.learnsFromClips = false
        for _ in 0..<400 where counts.cancelledCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let scheduledBefore = counts.scheduledCount
        settings.learnsFromClips = true
        for _ in 0..<400 where counts.scheduledCount == scheduledBefore {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(counts.scheduledCount, scheduledBefore)
        model.releaseHeldRun()

        let finished = await rebuild.value
        await layer.settle()

        XCTAssertTrue(finished)
        let cache = try XCTUnwrap(cacheStore.load())
        XCTAssertTrue(cache.isRebuilt)
        XCTAssertEqual(cache.rebuiltPoseIDs.count, 3)
        XCTAssertEqual(cache.clips.count, 3)
        XCTAssertEqual(model.runCount, 4)
    }

    // MARK: - The real model

    /// The rebuild reads a stored pose the way analysis read the frames, so a clip comes out with the
    /// embedding the save gave it.
    func testRebuiltEmbeddingsMatchTheOnesAnalysisGave() async throws {
        let artifact = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "TrickDetectorSmoke.mlpackage.zip", withExtension: nil))
        let model = try await TrickModel.load(artifact: artifact, version: "trick-v0.0-smoke")
        let reference = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "TrickModelReference.json", withExtension: nil))
        let samples = try JSONDecoder().decode(ReferencePose.self, from: Data(contentsOf: reference))
        let slots = samples.pose.map { $0[51] == 1 ? nil : Array($0[0..<51]) }
        let pose = ContributionPose(sampleRate: 10, slots: slots)
        let window = TrickWindow(startTime: 1, endTime: 3)

        let direct = try XCTUnwrap(try model.windowEmbeddings(over: pose)?.clipEmbedding(of: window))
        let poseID = try XCTUnwrap(library.poseStore.store(pose))
        let saved = LibrarySave(
            sourceAssetID: "source", sourceDuration: 6.4,
            clips: [
                LibrarySave.Clip(
                    id: UUID(), window: window, exportAssetID: "export", names: [PersonalFixture.typed("cork")],
                    isMe: true, isAutoDetected: true, proposal: nil, poseID: poseID)
            ])
        library.record(saved, sourceRecordedAt: nil)
        let layer = makeLayer(model: model)
        _ = await layer.rebuild()
        await layer.settle()

        let rebuilt = try XCTUnwrap(cacheStore.load()?.clips[saved.clips[0].id.uuidString])
        XCTAssertEqual(rebuilt.modelVersion, "trick-v0.0-smoke")
        XCTAssertEqual(rebuilt, direct)
        XCTAssertEqual(rebuilt.vector.dot(rebuilt.vector), 1, accuracy: 1e-4)
        XCTAssertFalse(rebuilt.centralNames.isEmpty)
    }

    private struct ReferencePose: Decodable {
        let pose: [[Float]]
    }
}

/// The cache's file: derived data, so anything but a good read of the current schema reads as absent.
final class PersonalCacheStoreTests: XCTestCase {
    private var url: URL!
    private var store: PersonalCacheStore { PersonalCacheStore(fileURL: url) }

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-cache-test-\(UUID().uuidString)/cache.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    func testACacheRoundTrips() {
        var cache = PersonalCache(modelVersion: "v1")
        cache.clips["id"] = ClipEmbedding(modelVersion: "v1", vector: [0.6, 0.8], centralNames: ["cork"])
        cache.rebuiltPoseIDs = ["pose"]
        cache.isRebuilt = true
        store.save(cache)
        XCTAssertEqual(store.load(), cache)
    }

    func testNoFileReadsAsAbsent() {
        XCTAssertNil(store.load())
    }

    func testAnUnreadableFileReadsAsAbsent() throws {
        store.save(PersonalCache(modelVersion: "v1"))
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(store.load())
    }

    func testAnotherSchemaReadsAsAbsent() {
        var cache = PersonalCache(modelVersion: "v1")
        cache.schemaVersion = PersonalCache.currentSchemaVersion + 1
        store.save(cache)
        XCTAssertNil(store.load())
    }

    func testDeletingRemovesTheFile() {
        store.save(PersonalCache(modelVersion: "v1"))
        store.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// It lives in `Caches/`, which iOS may evict and backups leave out.
    func testTheCacheLivesInCaches() throws {
        let url = try XCTUnwrap(PersonalCacheStore.defaultFileURL)
        XCTAssertTrue(url.path.contains("/Library/Caches/"), url.path)
    }
}

/// What Name Clips hands the layer: each clip's embedding from its own person's run, at save and while
/// it is named.
@MainActor
final class NameClipsPersonalizationTests: XCTestCase {
    private let descriptor = TrickModelDescriptor(classes: ["background", "cork"], windowFrames: 10, windowStride: 5)

    private func windows(personID: Int?, axis: Int) -> WindowEmbeddings {
        WindowEmbeddings(
            personID: personID, modelVersion: "v1", descriptor: descriptor,
            rows: (0..<40).map { _ in PersonalFixture.axis(axis) },
            probabilities: (0..<40).map { _ in [0, 1] })
    }

    private func item(
        _ start: TimeInterval, end: TimeInterval? = nil, personID: Int? = nil, proposal: ModelProposal? = nil
    ) -> ClipListItem {
        ClipListItem(
            window: TrickWindow(startTime: start, endTime: end ?? start + 2),
            cropRect: NormalizedRect(minX: 0, maxX: 1, minY: 0, maxY: 1), personID: personID, proposal: proposal)
    }

    private func model(
        _ items: [ClipListItem], embeddings: [WindowEmbeddings], people: [PoseTrack] = [],
        recordSaved: @escaping RecordSavedClips = { _ in [] }, rankNames: @escaping RankClipNames = { _, _, used, _ in
            PersonalSuggestions(used: used)
        }
    ) -> ClipListViewModel {
        ClipListViewModel(
            items: items, people: people, windowEmbeddings: embeddings,
            asset: AVURLAsset(url: URL(fileURLWithPath: "/dev/null")), assetIdentifier: "source", duration: 30,
            exportClip: { _, _, directory, _ in directory.appendingPathComponent("clip.mp4") },
            saveToPhotos: { _, _ in "asset" }, recordSaved: recordSaved, storePose: { _, _ in nil },
            rankNames: rankNames,
            makeDirectory: {
                FileManager.default.temporaryDirectory.appendingPathComponent("turnip-test-\(UUID().uuidString)")
            },
            settingsProvider: { TurnipSettings() }, announce: { _ in }, announceAfterScreenChange: { _ in })
    }

    func testFollowingOnePersonAClipReadsTheOneRun() {
        let viewModel = model([item(1)], embeddings: [windows(personID: nil, axis: 2)])
        let embedding = viewModel.embedding(of: viewModel.clipsToName[0])
        XCTAssertEqual(embedding?.vector, PersonalFixture.axis(2))
    }

    func testFollowingEveryoneAClipReadsItsOwnPersonsRun() {
        let viewModel = model(
            [item(1, personID: 3), item(4, personID: 0)],
            embeddings: [windows(personID: 0, axis: 1), windows(personID: 3, axis: 5)])
        XCTAssertEqual(viewModel.embedding(of: viewModel.clipsToName[0])?.vector, PersonalFixture.axis(5))
        XCTAssertEqual(viewModel.embedding(of: viewModel.clipsToName[1])?.vector, PersonalFixture.axis(1))
    }

    func testFollowingEveryoneAClipAddedByHandHasNoEmbedding() {
        let viewModel = model([item(1)], embeddings: [windows(personID: 0, axis: 1)])
        XCTAssertNil(viewModel.embedding(of: viewModel.clipsToName[0]))
    }

    func testTheHeuristicLeavesNoEmbedding() {
        let viewModel = model([item(1)], embeddings: [])
        XCTAssertNil(viewModel.embedding(of: viewModel.clipsToName[0]))
    }

    /// A trim moves the clip's window, and so which rows it reads.
    func testAClipsEmbeddingFollowsItsWindowAsItStands() {
        let rows = (0..<40).map { PersonalFixture.axis($0 < 10 ? 1 : 3) }
        let embeddings = WindowEmbeddings(
            personID: nil, modelVersion: "v1", descriptor: descriptor, rows: rows,
            probabilities: rows.map { _ in [0, 1] })
        let viewModel = model([item(0, end: 1), item(10, end: 12)], embeddings: [embeddings])
        XCTAssertEqual(viewModel.embedding(of: viewModel.clipsToName[0])?.vector, PersonalFixture.axis(1))
        XCTAssertEqual(viewModel.embedding(of: viewModel.clipsToName[1])?.vector, PersonalFixture.axis(3))
    }

    func testASaveCarriesEachClipsEmbedding() async {
        var saves: [LibrarySave] = []
        let viewModel = model(
            [item(1)], embeddings: [windows(personID: nil, axis: 2)], recordSaved: { saves.append($0); return [] })

        _ = await viewModel.save()

        XCTAssertEqual(saves.last?.clips.first?.embedding?.vector, PersonalFixture.axis(2))
        XCTAssertEqual(saves.last?.clips.first?.embedding?.modelVersion, "v1")
    }

    func testRankingSeesTheClipsEmbeddingProposalAndNames() {
        let proposal = ModelProposal(modelVersion: "v1", suggestedNames: [], suggestionsWithheld: true)
        var seenEmbedding: ClipEmbedding?
        var seenProposal: ModelProposal?
        var seenUsed: [String] = []
        var seenGiven: [ClipName] = []
        let viewModel = model(
            [item(1, proposal: proposal)], embeddings: [windows(personID: nil, axis: 2)],
            rankNames: { embedding, proposal, used, given in
                seenEmbedding = embedding
                seenProposal = proposal
                seenUsed = used
                seenGiven = given
                return PersonalSuggestions(used: used, nearest: ["flash kick"])
            })
        let id = viewModel.clipsToName[0].id
        viewModel.addName("cork", origin: .typed, to: id)

        let suggestions = viewModel.suggestions(for: viewModel.clipsToName[0])

        XCTAssertEqual(suggestions.nearest, ["flash kick"])
        XCTAssertEqual(seenEmbedding?.vector, PersonalFixture.axis(2))
        XCTAssertEqual(seenProposal, proposal)
        XCTAssertEqual(seenUsed, ["cork"])
        XCTAssertEqual(seenGiven.map(\.name), ["cork"])
    }

    /// A pre-fill is the central model's alone: ranking runs after it, and adds no chip.
    func testRankingNeverPreFillsAName() {
        let viewModel = model(
            [item(1)], embeddings: [windows(personID: nil, axis: 2)],
            rankNames: { _, _, used, _ in PersonalSuggestions(used: used, nearest: ["flash kick"]) })
        _ = viewModel.suggestions(for: viewModel.clipsToName[0])
        XCTAssertEqual(viewModel.clipsToName[0].names, [])
    }
}
