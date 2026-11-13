import Combine
import Foundation
import Network
import os
import UIKit

/// One save's contribution, waiting until the farm holds it or refuses it.
struct OutboxJob: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let enqueuedAt: Date
    let source: SourceContribution
}

/// The outbox on disk: one JSON file per job in `Application Support/ContributionOutbox/`, written
/// atomically, so a job outlives the app being killed mid-upload. Left out of device backups: a
/// job is pose data with no use elsewhere, since the source keys it needs never leave this iPhone.
actor ContributionOutboxStore {
    private let directory: URL?

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "ContributionOutbox")

    init(directory: URL?) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ContributionOutbox", isDirectory: true)
    }

    /// Every job on disk. A file this build can't read is removed, so it can't sit in the queue
    /// forever unsent.
    func load() -> [OutboxJob] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    /// A failed write is logged and leaves the job in memory for this run.
    func write(_ job: OutboxJob) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var backupTarget = directory
            try backupTarget.setResourceValues(excluded)
            try Self.encoder().encode(job).write(to: file(for: job.id, in: directory), options: .atomic)
        } catch {
            Self.logger.error("Couldn't keep a job: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ id: UUID) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: file(for: id, in: directory))
    }

    func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func read(_ file: URL) -> OutboxJob? {
        do {
            return try Self.decoder().decode(OutboxJob.self, from: Data(contentsOf: file))
        } catch {
            Self.logger.error("Dropped an unreadable job: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    private func file(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// The pose is the model's raw output, unclamped: JSON has no NaN or infinity, and without a
    /// spelling for them one such value would cost the whole job.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
}

/// Sends what a save contributes without holding the app up (`docs/CONTRIBUTION_DESIGN.md` §5.3):
/// a job goes on disk first, then runs through `ContributionUploader` off the main actor, oldest
/// first, one at a time. Nothing waits on it and nothing reports back to a screen.
///
/// A job that fails for a reason that can pass stays queued and is tried again after a growing
/// wait, or at once when the app returns to the foreground, the network comes back or the user
/// signs in. Every upload step is an upsert, so starting a job over is always safe. A job the farm
/// refuses for good is dropped: its clips stay saved, and only the log records it.
///
/// Nothing is sent while Contribute named clips is off, no one is signed in, or the signed-in
/// account hasn't agreed to the disclosure. Turning the switch off cancels everything queued;
/// signing out only pauses it.
@MainActor
final class ContributionOutbox: ObservableObject {
    static let shared = ContributionOutbox(
        account: .shared, settings: .shared,
        store: ContributionOutboxStore(directory: ContributionOutboxStore.defaultDirectory),
        savedClip: { ClipLibrary.shared.clip($0) })

    /// What a failed attempt means for its job.
    enum Disposition: Equatable {
        /// It can pass. `after` is how long the farm asked to be left alone, when it asked.
        case retry(after: TimeInterval?)
        /// Another try gets the same answer.
        case drop
        /// The session is gone; the job waits for the next sign-in.
        case signIn
    }

    private enum Attempt {
        case settled
        case retry(after: TimeInterval?)
        case stopped
    }

    /// How long a job stays queued before it is given up on, so pose data a farm fault keeps from
    /// landing doesn't sit on the device and retry forever.
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    /// The farm's codes for what it will never accept as sent (`BACKEND_DESIGN.md` §7.2). Anything
    /// else it answers with stays retryable, `INTERNAL` included.
    private static let permanentRefusals: Set<String> = ["VALIDATION_ERROR", "UNSUPPORTED_FORMAT", "NOT_FOUND"]

    private static let logger = Logger(subsystem: "com.hoiekim.turnip", category: "ContributionOutbox")

    @Published private(set) var jobs: [OutboxJob] = []
    private(set) var drain: Task<Void, Never>?

    private let account: FarmAccount
    private let settings: TurnipSettingsStore
    private let store: ContributionOutboxStore
    private let savedClip: @MainActor (UUID) -> LibraryClip?
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true
    private var hasLoaded = false
    private var backoff: Task<Void, Never>?
    /// The current wait is one the farm asked for, so nothing but a stop cuts it short.
    private var isRateLimited = false
    private var resumesWhenDrained = false
    private var observers: Set<AnyCancellable> = []

    init(
        account: FarmAccount,
        settings: TurnipSettingsStore,
        store: ContributionOutboxStore,
        savedClip: @escaping @MainActor (UUID) -> LibraryClip?,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.account = account
        self.settings = settings
        self.store = store
        self.savedClip = savedClip
        self.now = now
        self.sleep = sleep
        observe()
    }

    deinit {
        pathMonitor.cancel()
    }

    var waitingClipCount: Int {
        jobs.reduce(0) { $0 + $1.source.clips.count }
    }

    private var canSend: Bool {
        settings.contributesClips && account.isSignedIn && account.credentials.hasConsented
    }

    // MARK: - Queueing

    /// The confirmation sheet's Confirm: the agreement every later save rides on, and this save's
    /// clips.
    func confirm(_ source: SourceContribution) async {
        account.credentials.recordConsent()
        await enqueue(source)
    }

    func enqueue(_ source: SourceContribution) async {
        let job = OutboxJob(id: UUID(), enqueuedAt: now(), source: source)
        jobs.append(job)
        await store.write(job)
        resume()
    }

    /// Sends whatever is waiting, starting now even if a retry's wait has time left: called
    /// whenever sending may have become possible again.
    func resume() {
        if !isRateLimited { backoff?.cancel() }
        guard drain == nil else {
            resumesWhenDrained = true
            return
        }
        drain = Task { [weak self] in
            await self?.run()
            self?.drained()
        }
    }

    /// Stops any upload under way, then forgets everything queued. Returns once nothing can be in
    /// flight, so a caller can act on what the farm holds.
    func cancelAll() async {
        stop()
        await drain?.value
        jobs = []
        await store.removeAll()
    }

    /// Deletes the farm account, with everything queued cancelled first so no upload can reach a
    /// source after its deletion. The agreement goes before the cancel as well as with the
    /// account: a resume landing during the cancel must find nothing it may send.
    func deleteAccount() async throws {
        account.credentials.withdrawConsent()
        await cancelAll()
        try await account.deleteAccount()
    }

    private func stop() {
        resumesWhenDrained = false
        backoff?.cancel()
        drain?.cancel()
    }

    // MARK: - Draining

    private func drained() {
        drain = nil
        guard resumesWhenDrained else { return }
        resumesWhenDrained = false
        resume()
    }

    private func run() async {
        await loadStoredJobs()
        await dropExpiredJobs()
        var failedPasses = 0
        while canSend, !jobs.isEmpty, !Task.isCancelled {
            switch await attemptEachJob() {
            case .settled:
                failedPasses = 0
            case .stopped:
                return
            case .retry(let requested):
                failedPasses += 1
                await waitToRetry(
                    after: requested ?? Self.backoff(afterFailedPasses: failedPasses), isRateLimit: requested != nil)
            }
        }
    }

    private func loadStoredJobs() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        let stored = await store.load()
        let known = Set(jobs.map(\.id))
        jobs = (jobs + stored.filter { !known.contains($0.id) }).sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    private func dropExpiredJobs() async {
        for job in jobs where now().timeIntervalSince(job.enqueuedAt) > Self.maximumAge {
            Self.logger.error("Gave up on a job past its maximum age")
            await remove(job)
        }
    }

    /// One try at each job, so a job that keeps failing doesn't hold back those behind it.
    private func attemptEachJob() async -> Attempt {
        var pass = Attempt.settled
        for job in jobs {
            guard canSend, !Task.isCancelled else { return .stopped }
            switch await attempt(job) {
            case .settled: await remove(job)
            case .stopped: return .stopped
            case .retry(after: let delay?): return .retry(after: delay)
            case .retry(after: nil): pass = .retry(after: nil)
            }
        }
        return pass
    }

    private func attempt(_ job: OutboxJob) async -> Attempt {
        guard let source = currentSource(of: job) else { return .settled }
        guard let client = account.client, let session = account.credentials.sessionToken else { return .stopped }
        let backgroundTime = BackgroundTime()
        defer { backgroundTime.end() }
        do {
            let uploader = ContributionUploader(client: client, credentials: account.credentials)
            let stored = try await uploader.contribute(source, session: session)
            guard source.clipsNotHeld(by: stored).isEmpty else {
                Self.logger.error("The farm's read-back doesn't hold what was sent")
                return .retry(after: nil)
            }
            return .settled
        } catch {
            switch Self.disposition(of: error) {
            case .retry(let delay):
                return .retry(after: delay)
            case .drop:
                Self.logger.error("Dropped a job the farm refused: \(error.localizedDescription, privacy: .public)")
                return .settled
            case .signIn:
                // A sign-in that landed during the attempt has a session this 401 says nothing about.
                guard account.credentials.sessionToken == session else { return .retry(after: nil) }
                account.sessionEnded()
                return .stopped
            }
        }
    }

    /// The job as it stands now: a job can wait for days, and a clip removed from the library
    /// meanwhile must not go out, nor one since marked as someone else, nor names the user has since
    /// changed. `nil` when no clip is left.
    private func currentSource(of job: OutboxJob) -> SourceContribution? {
        let clips = job.source.clips.compactMap { clip -> ClipContribution? in
            guard let saved = savedClip(clip.clipID), saved.isMe, !saved.names.isEmpty else { return nil }
            var current = clip
            current.names = saved.names
            return current
        }
        guard !clips.isEmpty else { return nil }
        return SourceContribution(videoID: job.source.videoID, pose: job.source.pose, clips: clips)
    }

    private func remove(_ job: OutboxJob) async {
        jobs.removeAll { $0.id == job.id }
        await store.remove(job.id)
    }

    private func waitToRetry(after delay: TimeInterval, isRateLimit: Bool) async {
        guard !Task.isCancelled else { return }
        isRateLimited = isRateLimit
        let sleep = self.sleep
        let waiting = Task { _ = try? await sleep(delay) }
        backoff = waiting
        await waiting.value
        backoff = nil
        isRateLimited = false
    }

    /// Doubles from 30 seconds to an hour.
    static func backoff(afterFailedPasses passes: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(passes, 1) - 1)), 3600)
    }

    static func disposition(of error: Error) -> Disposition {
        switch error as? FarmError {
        case .unauthenticated:
            return .signIn
        case .sourceAlreadyClaimed, .accountBlocked:
            return .drop
        case .rateLimited(let retryAfter):
            return .retry(after: retryAfter)
        case .rejected(let code, _) where permanentRefusals.contains(code):
            return .drop
        default:
            return error is PoseEncodingError ? .drop : .retry(after: nil)
        }
    }

    // MARK: - Triggers

    private func observe() {
        // `@Published` reports from `willSet`, so each reaction runs a turn later, when `canSend`
        // reads the new value. The first report is the stored value: a queue left behind with the
        // switch off is cleared, and a signed-in launch starts draining.
        settings.$contributesClips
            .sink { [weak self] isOn in
                Task { @MainActor in
                    if isOn { self?.resume() } else { await self?.cancelAll() }
                }
            }
            .store(in: &observers)
        account.$isSignedIn
            .sink { [weak self] isSignedIn in
                Task { @MainActor in
                    if isSignedIn { self?.resume() } else { self?.stop() }
                }
            }
            .store(in: &observers)
        guard account.isAvailable else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isOnline: isSatisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.hoiekim.turnip.contribution-outbox", qos: .utility))
    }

    func networkChanged(isOnline: Bool) {
        let cameBack = isOnline && !self.isOnline
        self.isOnline = isOnline
        if cameBack { resume() }
    }
}

/// The seconds iOS grants an app that has just left the foreground, held for one attempt, so a
/// save followed by leaving the app still gets its upload out. When they run out, the attempt
/// freezes with the app; its failure is retried at the next `resume()`.
@MainActor
private final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Contribution upload") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
