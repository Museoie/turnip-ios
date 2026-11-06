import Combine
import Foundation
import os

/// What the rebuild needs of the trick model: its version, and a run over a stored pose.
protocol PoseEmbedder: Sendable {
    var version: String { get }
    var hasEmbeddings: Bool { get }
    func windowEmbeddings(over pose: ContributionPose) throws -> WindowEmbeddings?
}

extension TrickModel: PoseEmbedder {
    func windowEmbeddings(over pose: ContributionPose) throws -> WindowEmbeddings? {
        try run(TrickModelInput(pose: pose)).flatMap { windowEmbeddings(of: $0, personID: nil) }
    }
}

/// How the layer asks for the rebuild to run, and calls it off.
struct PersonalRebuildScheduler: Sendable {
    var schedule: @Sendable () -> Void
    var cancel: @Sendable () -> Void
}

/// The device's personal layer over the central model (`docs/PERSONALIZATION_DESIGN.md`): it keeps
/// each saved clip's embedding under the active model, and offers name ranking while that beats the
/// central model on the user's own clips. In every other case, with the toggle off, too few clips,
/// a rebuild in progress or a model without embeddings, `ranking` is `nil` and the app behaves as
/// `MODEL_CONTRACT.md` §3.3 says.
///
/// `@MainActor` because the naming screens read `ranking` as they draw. The work behind it, the
/// gate, the cache's file and the rebuild's model runs, stays off the main actor. Nothing here
/// leaves the device or is logged beyond counts.
@MainActor
final class PersonalLayer {
    static let shared = PersonalLayer(
        library: .shared, settings: .shared, vocabulary: { VocabularyStore.shared.current },
        cacheStore: PersonalCacheStore(fileURL: PersonalCacheStore.defaultFileURL),
        activeVersion: { ModelUpdateStore.production?.activeModel()?.version.rawValue },
        loadModel: { await TrickModelLoader.shared.model() },
        scheduler: PersonalRebuildTask.scheduler)

    /// Name ranking when it is in use, `nil` otherwise.
    private(set) var ranking: PersonalNameRanking?

    private let library: ClipLibrary
    private let vocabulary: @MainActor () -> TrickVocabulary
    private let cacheStore: PersonalCacheStore
    private let activeVersion: @Sendable () -> String?
    private let loadModel: @Sendable () async -> PoseEmbedder?
    private let scheduler: PersonalRebuildScheduler
    private let isTooHot: @Sendable () -> Bool
    private var isEnabled: Bool
    private var cache: PersonalCache?
    private var rankingTask: Task<Void, Never>?
    /// The last write or delete of the cache's file: each waits on the one before, so the file
    /// ends as the last call left it.
    private var lastFileChange: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    private nonisolated static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "Personalization")

    /// `namingSettles` is how long the library stays quiet before a name given on the Profile, which
    /// has no save of its own, reaches the prototypes.
    init(
        library: ClipLibrary,
        settings: TurnipSettingsStore,
        vocabulary: @escaping @MainActor () -> TrickVocabulary,
        cacheStore: PersonalCacheStore,
        activeVersion: @escaping @Sendable () -> String?,
        loadModel: @escaping @Sendable () async -> PoseEmbedder?,
        scheduler: PersonalRebuildScheduler,
        isTooHot: @escaping @Sendable () -> Bool = { PersonalLayer.thermalStateIsTooHot },
        namingSettles: DispatchQueue.SchedulerTimeType.Stride = .seconds(1)
    ) {
        self.library = library
        self.vocabulary = vocabulary
        self.cacheStore = cacheStore
        self.activeVersion = activeVersion
        self.loadModel = loadModel
        self.scheduler = scheduler
        self.isTooHot = isTooHot
        isEnabled = settings.learnsFromClips
        settings.$learnsFromClips
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isOn in
                Task { @MainActor in await self?.setEnabled(isOn) }
            }
            .store(in: &subscriptions)
        library.$clips
            .dropFirst()
            .debounce(for: namingSettles, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &subscriptions)
    }

    /// Serious or worse, as live pose backs off (`LivePoseThermalPolicy`).
    nonisolated static var thermalStateIsTooHot: Bool {
        LivePoseThermalPolicy.response(to: ProcessInfo.processInfo.thermalState) != .normal
    }

    // MARK: - Reading

    /// What ranking adds for a clip with `embedding`, or the names as they came when it adds
    /// nothing. Withheld on a blind clip, where even their order stays plain
    /// (`MODEL_CONTRACT.md` §3.3 step 5).
    func suggestions(
        for embedding: ClipEmbedding?, proposal: ModelProposal?, used: [String], given: [ClipName]
    ) -> PersonalSuggestions {
        guard proposal?.suggestionsWithheld != true, let embedding, let ranking,
              ranking.modelVersion == embedding.modelVersion
        else { return PersonalSuggestions(used: used) }
        return ranking.suggestions(for: embedding.vector, used: used, given: given)
    }

    /// The same for a saved clip, whose embedding the cache holds.
    func suggestions(forSaved clip: LibraryClip, used: [String]) -> PersonalSuggestions {
        suggestions(
            for: cache?.clips[clip.id.uuidString], proposal: clip.proposal, used: used, given: clip.names)
    }

    // MARK: - Keeping up

    /// Brings the layer to the active model: picks up the cache built against it, or drops another
    /// version's and starts again from the library (`MODEL_CONTRACT.md` §4). Safe to call as often
    /// as the app comes forward.
    ///
    /// Goes by the store's active version and never loads the model. `TrickModelLoader` loads once
    /// per launch and keeps what it found, so a load from here, beside the launch's update check,
    /// would keep a model staged moments later from every analysis of that launch, and the toggle
    /// would decide which central model analysis uses. A version the first analysis activates
    /// reaches the layer the next time the app comes forward.
    func start() async {
        guard isEnabled else { return }
        let activeVersion = activeVersion
        let active = await Task.detached(priority: .utility) { activeVersion() }.value
        guard let version = active else {
            cache = nil
            ranking = nil
            return
        }
        guard cache?.modelVersion != version else {
            refresh()
            return
        }
        let store = cacheStore
        let pending = lastFileChange
        // Behind any change still queued: read ahead of the toggle's delete, the file it was turned
        // off to remove would come back.
        let stored = await Task.detached(priority: .utility) { () -> PersonalCache? in
            await pending?.value
            return store.load()
        }.value
        // The toggle can go off, or another start land, while the file was being read.
        guard isEnabled, cache?.modelVersion != version else { return }
        if let stored, stored.modelVersion == version {
            cache = stored
        } else {
            var fresh = PersonalCache(modelVersion: version)
            fresh.isRebuilt = !library.clips.contains { $0.poseID != nil }
            cache = fresh
        }
        refresh()
    }

    /// A save's embeddings, from the analysis that just ran (§6.1). Nothing else to do: no model
    /// runs over earlier sources.
    func record(_ save: LibrarySave) {
        guard isEnabled, var cache else { return }
        for clip in save.clips {
            guard let embedding = clip.embedding, embedding.modelVersion == cache.modelVersion else { continue }
            cache.clips[clip.id.uuidString] = embedding
        }
        self.cache = cache
        refresh()
    }

    /// Works prototypes and the gate out again from the library's current names, off the main actor,
    /// and keeps the cache's file in step. Clips gone from the library leave the cache here.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        rankingTask?.cancel()
        guard isEnabled, var cache else {
            ranking = nil
            return Task {}
        }
        let clips = library.clips
        let known = Set(clips.map(\.id.uuidString))
        cache.clips = cache.clips.filter { known.contains($0.key) }
        self.cache = cache
        persist(cache)
        guard cache.isRebuilt else {
            ranking = nil
            scheduler.schedule()
            return Task {}
        }
        let vocabulary = vocabulary()
        let task = Task { [weak self] in
            let ranking = await Task.detached(priority: .utility) {
                Self.ranking(of: clips, cache: cache, vocabulary: vocabulary)
            }.value
            guard !Task.isCancelled else { return }
            self?.ranking = ranking
        }
        rankingTask = task
        return task
    }

    private nonisolated static func ranking(
        of clips: [LibraryClip], cache: PersonalCache, vocabulary: TrickVocabulary
    ) -> PersonalNameRanking? {
        let examples = PersonalExample.examples(from: clips, embeddings: cache.clips, vocabulary: vocabulary)
        guard let outcome = NameRankingGate.outcome(of: examples) else { return nil }
        logger.notice("""
            Name ranking gate: \(outcome.clips) clips, personal \(outcome.personalHits), \
            central \(outcome.centralHits)
            """)
        guard outcome.passes else { return nil }
        return PersonalNameRanking(
            modelVersion: cache.modelVersion, prototypes: NamePrototypes(examples).all(), vocabulary: vocabulary)
    }

    private func setEnabled(_ isOn: Bool) async {
        isEnabled = isOn
        guard !isOn else {
            await start()
            return
        }
        rankingTask?.cancel()
        ranking = nil
        cache = nil
        scheduler.cancel()
        changeFile { $0.delete() }
    }

    private func persist(_ cache: PersonalCache) {
        changeFile { $0.save(cache) }
    }

    private func changeFile(_ change: @escaping @Sendable (PersonalCacheStore) -> Void) {
        let store = cacheStore
        let previous = lastFileChange
        lastFileChange = Task.detached(priority: .utility) {
            await previous?.value
            change(store)
        }
    }

    /// Waits for what `refresh` and the cache's file have in flight.
    func settle() async {
        await rankingTask?.value
        await lastFileChange?.value
    }

    // MARK: - Rebuilding

    /// The second pass after a model update (§6.2): runs the model over each stored pose not yet
    /// done, keeping its clips' embeddings, then turns the layer back on through the gate. Picks up
    /// where the last run stopped. Returns whether it finished; it stops early when `shouldStop`
    /// says so or the device runs hot, and asks to run again.
    ///
    /// Each pass picks its pose from the cache as it stands, because turning the toggle off and on
    /// mid-run starts the cache over and the poses already done have to run again. A model without
    /// embeddings, which only its load can show, has nothing to run: the rebuild ends there and the
    /// layer stays off, with no clip to rank.
    @discardableResult
    func rebuild(shouldStop: @escaping @Sendable () -> Bool = { false }) async -> Bool {
        await start()
        guard isEnabled, cache?.isRebuilt == false, let model = await loadModel() else { return true }
        // This load can be the one that activates a staged model, and the layer follows it.
        await start()
        let clipsWithPose = model.hasEmbeddings ? library.clips.filter { $0.poseID != nil } : []
        let clipsByPose = Dictionary(grouping: clipsWithPose) { $0.poseID ?? "" }
        let sortedPoses = clipsByPose.sorted { $0.key < $1.key }
        let poses = library.poseStore
        while isEnabled, let started = cache, started.modelVersion == model.version,
              let (poseID, clips) = sortedPoses.first(where: { !started.rebuiltPoseIDs.contains($0.key) }) {
            guard !shouldStop(), !isTooHot() else {
                scheduler.schedule()
                return false
            }
            let windows = clips.map { (id: $0.id, window: TrickWindow(startTime: $0.startTime, endTime: $0.endTime)) }
            let embeddings = await Task.detached(priority: .utility) {
                Self.embeddings(of: windows, poseID: poseID, poses: poses, model: model)
            }.value
            guard isEnabled, var current = self.cache, current.modelVersion == model.version else { return false }
            current.clips.merge(embeddings) { _, rebuilt in rebuilt }
            current.rebuiltPoseIDs.insert(poseID)
            self.cache = current
            persist(current)
        }
        guard isEnabled, var finished = self.cache, finished.modelVersion == model.version else { return false }
        finished.isRebuilt = true
        self.cache = finished
        scheduler.cancel()
        await refresh().value
        Self.logger.notice("Personal rebuild finished: \(clipsByPose.count) poses, \(finished.clips.count) clips")
        return true
    }

    /// One stored pose's clips under `model`. A pose that can't be read or run contributes nothing
    /// and isn't tried again, so one bad file can't hold the layer off.
    private nonisolated static func embeddings(
        of clips: [(id: UUID, window: TrickWindow)], poseID: String, poses: SourcePoseStore, model: PoseEmbedder
    ) -> [String: ClipEmbedding] {
        guard let pose = poses.pose(poseID) else { return [:] }
        do {
            guard let rows = try model.windowEmbeddings(over: pose) else { return [:] }
            var embeddings: [String: ClipEmbedding] = [:]
            for clip in clips {
                embeddings[clip.id.uuidString] = rows.clipEmbedding(of: clip.window)
            }
            return embeddings
        } catch {
            logger.error("Personal rebuild skipped a pose: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }
}
