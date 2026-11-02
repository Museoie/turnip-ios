import Foundation
import os

/// Loads the trick model the OTA update staged, once per launch, for every analysis to share.
///
/// Once, so a session never switches models partway: an update staged after the load waits for
/// the next launch, and the loaded model is kept, never reloaded from the store, whose files
/// the next update may replace.
///
/// A model staged since the last load is tried first. If it loads, the store makes it the active
/// model and lets the one before it go; if it doesn't, the store deletes it and the active model,
/// kept for exactly this, loads instead (`MODEL_CONTRACT.md` §4). `model()` returns `nil` when
/// nothing is staged or nothing staged loads. Analysis then proposes clips with the heuristic
/// `TrickWindowDetector`, so the app is never without a proposal path.
actor TrickModelLoader {
    static let shared = TrickModelLoader(store: ModelUpdateStore.production)

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "TrickModel")
    private let store: ModelUpdateStore?
    private var loading: Task<TrickModel?, Never>?

    init(store: ModelUpdateStore?) {
        self.store = store
    }

    /// The loaded model, loading it on the first call; later and overlapping calls share that
    /// first load, failed or not.
    func model() async -> TrickModel? {
        if let loading { return await loading.value }
        let store = store
        let task = Task.detached(priority: .userInitiated) { await Self.load(from: store) }
        loading = task
        return await task.value
    }

    private static func load(from store: ModelUpdateStore?) async -> TrickModel? {
        guard let store else { return nil }
        if let pending = store.pendingModel() {
            if let model = await load(pending) {
                store.markLoaded(pending.version)
                return model
            }
            store.discard(pending.version)
        }
        guard let active = store.activeModel() else { return nil }
        return await load(active)
    }

    private static func load(_ staged: ModelUpdateStore.StagedModel) async -> TrickModel? {
        let version = staged.version.rawValue
        do {
            let model = try await TrickModel.load(artifact: staged.artifactURL, version: version)
            logger.notice("Loaded trick model \(version, privacy: .public)")
            return model
        } catch {
            let reason = String(describing: error)
            logger.error("Trick model \(version, privacy: .public) didn't load: \(reason, privacy: .public)")
            return nil
        }
    }
}
