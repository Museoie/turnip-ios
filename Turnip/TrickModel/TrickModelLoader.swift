import Foundation
import os

/// Loads the trick model the OTA update staged, once per launch, for every analysis to share.
///
/// Once, because the store deletes a staged artifact when the next update stages its own: the
/// path read at load may be gone by the next analysis, so the loaded model is kept, never
/// reloaded from it. An update staged during the session takes effect at the next launch.
///
/// `model()` returns `nil` when nothing is staged or the staged model fails to unpack, compile or
/// load. Analysis then proposes clips with the heuristic `TrickWindowDetector`, so the app is
/// never without a proposal path (`MODEL_CONTRACT.md` §4).
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
        guard let store, let artifact = store.activeModelURL(), let version = store.activeVersion() else {
            return nil
        }
        do {
            let model = try await TrickModel.load(artifact: artifact, version: version.rawValue)
            logger.notice("Loaded trick model \(version.rawValue, privacy: .public)")
            return model
        } catch {
            let reason = String(describing: error)
            logger.error("Trick model \(version.rawValue, privacy: .public) didn't load: \(reason, privacy: .public)")
            return nil
        }
    }
}
