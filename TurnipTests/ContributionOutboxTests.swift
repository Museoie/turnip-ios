import XCTest
@testable import Turnip

/// Records each retry wait, then holds it until something cuts it short.
private final class RetryWaits: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { recorded } }

    func record(_ delay: TimeInterval) {
        lock.withLock { recorded.append(delay) }
    }

    func hold(_ delay: TimeInterval) async throws {
        record(delay)
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

@MainActor
final class ContributionOutboxTests: XCTestCase {
    private static let videoID = String(repeating: "ab", count: 32)
    private static let otherVideoID = String(repeating: "cd", count: 32)
    private static let clipID = UUID(uuidString: "8F0E2C4A-1B2D-4E5F-9A0B-1C2D3E4F5A6B")!
    private static let otherClipID = UUID(uuidString: "1A0E2C4A-1B2D-4E5F-9A0B-1C2D3E4F5A6B")!
    private static let cork = [ClipName(name: "cork", origin: .typed)]

    private var directory: URL!
    private var outboxes: [ContributionOutbox] = []
    private let waits = RetryWaits()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnip-outbox-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for outbox in outboxes { await outbox.cancelAll() }
        outboxes = []
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func account(
        client: FarmClient, signedInAs user: String? = "user-1", consentedAs consenting: String? = "user-1"
    ) -> FarmAccount {
        let credentials = FarmCredentials(store: MemorySecrets())
        if let consenting {
            credentials.signedIn(sessionToken: "tok", appleUserID: consenting)
            credentials.recordConsent()
            credentials.signedOut()
        }
        if let user { credentials.signedIn(sessionToken: "tok", appleUserID: user) }
        return FarmAccount(client: client, credentials: credentials)
    }

    private func settings(contributes: Bool = true) -> TurnipSettingsStore {
        let suite = "ContributionOutboxTests-\(UUID().uuidString)"
        let store = TurnipSettingsStore(defaults: UserDefaults(suiteName: suite)!)
        store.contributesClips = contributes
        return store
    }

    private func outbox(
        _ account: FarmAccount,
        settings: TurnipSettingsStore? = nil,
        savedClip: ((UUID) -> LibraryClip?)? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) -> ContributionOutbox {
        let waits = self.waits
        let outbox = ContributionOutbox(
            account: account, settings: settings ?? self.settings(),
            store: ContributionOutboxStore(directory: directory),
            savedClip: savedClip ?? { Self.saved($0, names: Self.cork) }, now: now,
            sleep: sleep ?? { try await waits.hold($0) })
        outboxes.append(outbox)
        return outbox
    }

    private static func saved(_ id: UUID, names: [ClipName]) -> LibraryClip {
        LibraryClip(
            id: id, sourceAssetID: "asset", startTime: 1, endTime: 2, exportAssetID: "export", names: names,
            isMe: true, isAutoDetected: true, recordedAt: .distantPast, savedAt: .distantPast)
    }

    private nonisolated static func clip(_ id: UUID = clipID) -> ClipContribution {
        ClipContribution(
            clipID: id, window: TrickWindow(startTime: 1, endTime: 2), autoDetected: true, names: cork)
    }

    private static func source(
        _ videoID: String = videoID, clips: [ClipContribution] = [clip()]
    ) -> SourceContribution {
        SourceContribution(
            videoID: videoID,
            pose: ContributionPose(
                sampleRate: 10, slots: Array(repeating: Array(repeating: 0.5, count: 51), count: 30)),
            clips: clips)
    }

    private static func registered(_ videoID: String = videoID) -> ScriptedFarm.Reply {
        .init(status: 200, body: """
            {"source_id":"\(videoID)","r2_key":"poses/x.tkp1.gz","upload_url":"https://r2.test/put",\
            "upload_expires_at":"2026-10-06T08:00:00Z","blob_present":true}
            """)
    }

    private static let clipsTaken = ScriptedFarm.Reply(status: 200, body: #"{"clips":[]}"#)

    private static func readBack(_ ids: [UUID] = [clipID], names: String = "cork") -> ScriptedFarm.Reply {
        let clips = ids.map { id in
            """
            {"id":"\(id.uuidString.lowercased())","start_frame":10,"end_frame":20,\
            "labels":[{"name":"\(names)","origin":"typed"}]}
            """
        }
        return .init(status: 200, body: """
            {"source":{"id":"x","frame_count":30,"sha256":"d"},"clips":[\(clips.joined(separator: ","))]}
            """)
    }

    private static func delivered(_ videoID: String = videoID, _ ids: [UUID] = [clipID]) -> [ScriptedFarm.Reply] {
        [registered(videoID), clipsTaken, readBack(ids)]
    }

    private static func refusal(_ status: Int, _ code: String, headers: [String: String] = [:]) -> ScriptedFarm.Reply {
        .init(status: status, body: #"{"error":{"code":"\#(code)","message":"m"}}"#, headers: headers)
    }

    /// Answers nothing until cancelled, and says when a request has reached it, so a test can
    /// stop an upload that is really under way rather than one that hasn't started.
    private static func stalledClient(reached: Latch) -> FarmClient {
        FarmClient(baseURL: URL(string: "https://farm.test")!) { _ in
            reached.set()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw URLError(.timedOut)
        }
    }

    private func filesOnDisk() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func eventually(
        _ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        for _ in 0..<2500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("never happened: \(what)", file: file, line: line)
    }

    /// Well under `RetryWaits`' hold, so an outbox left retrying fails here instead of finishing
    /// late or hanging the run.
    private func settled(
        _ outbox: ContributionOutbox, file: StaticString = #filePath, line: UInt = #line
    ) async {
        await eventually("the outbox goes idle", file: file, line: line) { outbox.drain == nil }
    }

    // MARK: - Sending

    func testAQueuedJobGoesOutAndLeavesTheQueue() async {
        let farm = ScriptedFarm(Self.delivered())
        let outbox = outbox(account(client: farm.client))

        await outbox.enqueue(Self.source())
        await settled(outbox)

        XCTAssertEqual(farm.calls, [
            "POST /api/sources", "POST /api/clips", "GET /api/sources/\(Self.videoID)"
        ])
        XCTAssertTrue(outbox.jobs.isEmpty)
        XCTAssertEqual(filesOnDisk(), [])
    }

    /// The Confirm path: agreeing covers this save and every later one, so the same account's
    /// next save needs no sheet.
    func testConfirmRecordsTheAgreementAndSends() async {
        let farm = ScriptedFarm(Self.delivered())
        let account = account(client: farm.client, consentedAs: nil)
        let outbox = outbox(account)
        XCTAssertFalse(account.credentials.hasConsented)

        await outbox.confirm(Self.source())
        await settled(outbox)

        XCTAssertTrue(account.credentials.hasConsented)
        XCTAssertEqual(farm.calls.count, 3)
        XCTAssertTrue(outbox.jobs.isEmpty)
    }

    /// Killed mid-upload: the next launch's outbox finds the job on disk and finishes it.
    func testAJobOutlivesTheAppAndGoesOutOnTheNextLaunch() async {
        let farm = ScriptedFarm([])
        let first = outbox(account(client: farm.client, signedInAs: nil))
        await first.enqueue(Self.source())
        await settled(first)
        XCTAssertEqual(farm.calls, [], "signed out, nothing goes")
        XCTAssertEqual(filesOnDisk().count, 1)

        farm.script(Self.delivered())
        let second = outbox(account(client: farm.client))
        second.resume()
        await settled(second)

        XCTAssertEqual(farm.calls.count, 3)
        XCTAssertEqual(filesOnDisk(), [])
    }

    func testJobsGoOldestFirst() async throws {
        let farm = ScriptedFarm([])
        let early = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = ContributionOutboxStore(directory: directory)
        await store.write(OutboxJob(
            id: UUID(), enqueuedAt: early.addingTimeInterval(60), source: Self.source(Self.otherVideoID)))
        await store.write(OutboxJob(id: UUID(), enqueuedAt: early, source: Self.source()))
        farm.script(Self.delivered() + Self.delivered(Self.otherVideoID))

        let outbox = outbox(account(client: farm.client), now: { early })
        outbox.resume()
        await settled(outbox)

        XCTAssertEqual(farm.calls.filter { $0.hasPrefix("GET") }, [
            "GET /api/sources/\(Self.videoID)", "GET /api/sources/\(Self.otherVideoID)"
        ])
    }

    // MARK: - Retrying

    /// An interrupted upload stays queued, and sending again doesn't wait out the backoff once
    /// something says it may work: `resume()` is what foreground and network-back both call.
    func testAnInterruptedUploadResumesWithoutWaitingOutTheBackoff() async {
        let farm = ScriptedFarm([])
        let outbox = outbox(account(client: farm.client))

        await outbox.enqueue(Self.source())
        await eventually("the first wait") { waits.delays == [30] }
        XCTAssertEqual(outbox.jobs.count, 1)
        XCTAssertEqual(filesOnDisk().count, 1)

        farm.script(Self.delivered())
        outbox.resume()
        await settled(outbox)

        XCTAssertTrue(outbox.jobs.isEmpty)
        XCTAssertEqual(filesOnDisk(), [])
    }

    /// Only a connection coming back is news; a path update while already online isn't a reason
    /// to retry.
    func testTheNetworkComingBackResumesWithoutWaitingOutTheBackoff() async {
        let farm = ScriptedFarm([])
        let outbox = outbox(account(client: farm.client))
        await outbox.enqueue(Self.source())
        await eventually("the first wait") { waits.delays == [30] }
        let calls = farm.calls.count

        outbox.networkChanged(isOnline: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(farm.calls.count, calls, "still online, so nothing changed")

        farm.script(Self.delivered())
        outbox.networkChanged(isOnline: false)
        outbox.networkChanged(isOnline: true)
        await settled(outbox)

        XCTAssertTrue(outbox.jobs.isEmpty)
    }

    func testRepeatedFailuresWaitLongerEachTime() async {
        let farm = ScriptedFarm([])
        let waits = RetryWaits()
        let delivered = Self.delivered()
        let outbox = outbox(account(client: farm.client), sleep: { delay in
            waits.record(delay)
            if waits.delays.count == 3 { farm.script(delivered) }
        })

        await outbox.enqueue(Self.source())
        await settled(outbox)

        XCTAssertEqual(waits.delays, [30, 60, 120])
        XCTAssertTrue(outbox.jobs.isEmpty)
    }

    func testBackoffDoublesToAnHour() {
        XCTAssertEqual(
            (1...9).map(ContributionOutbox.backoff(afterFailedPasses:)),
            [30, 60, 120, 240, 480, 960, 1920, 3600, 3600])
    }

    /// `Retry-After` is the farm's to set: neither the backoff nor a foreground retries sooner.
    func testAFarmThatAsksForTimeGetsIt() async {
        let farm = ScriptedFarm([Self.refusal(429, "RATE_LIMITED", headers: ["Retry-After": "120"])])
        let outbox = outbox(account(client: farm.client))

        await outbox.enqueue(Self.source())
        await eventually("the farm's wait") { waits.delays == [120] }
        let calls = farm.calls.count
        outbox.resume()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(farm.calls.count, calls)
    }

    /// The farm answered 200 but kept other names: not delivered, so it stays queued.
    func testAReadBackWithoutTheNamesSentKeepsTheJob() async {
        let farm = ScriptedFarm([Self.registered(), Self.clipsTaken, Self.readBack(names: "gainer")])
        let outbox = outbox(account(client: farm.client))

        await outbox.enqueue(Self.source())
        await eventually("a retry wait") { waits.delays == [30] }

        XCTAssertEqual(outbox.jobs.count, 1)
    }

    func testAJobThatKeepsFailingDoesNotHoldUpTheNext() async {
        let farm = ScriptedFarm([Self.refusal(500, "INTERNAL")] + Self.delivered(Self.otherVideoID))
        let store = ContributionOutboxStore(directory: directory)
        let first = OutboxJob(id: UUID(), enqueuedAt: Date(timeIntervalSinceNow: -60), source: Self.source())
        await store.write(first)
        await store.write(OutboxJob(id: UUID(), enqueuedAt: Date(), source: Self.source(Self.otherVideoID)))

        let outbox = outbox(account(client: farm.client))
        outbox.resume()
        await eventually("a retry wait") { waits.delays == [30] }

        XCTAssertEqual(outbox.jobs.map(\.id), [first.id])
    }

    func testAJobPastItsMaximumAgeIsGivenUpOn() async {
        let farm = ScriptedFarm([])
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = ContributionOutboxStore(directory: directory)
        await store.write(OutboxJob(id: UUID(), enqueuedAt: start, source: Self.source()))

        let outbox = outbox(account(client: farm.client), now: {
            start.addingTimeInterval(ContributionOutbox.maximumAge + 1)
        })
        outbox.resume()
        await settled(outbox)

        XCTAssertEqual(farm.calls, [])
        XCTAssertEqual(filesOnDisk(), [])
    }

    // MARK: - What a failure means

    private func disposition(status: Int, code: String) -> ContributionOutbox.Disposition {
        let response = HTTPURLResponse(
            url: URL(string: "https://farm.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body = Data(#"{"error":{"code":"\#(code)","message":"m"}}"#.utf8)
        return ContributionOutbox.disposition(of: FarmClient.error(status: response, body: body))
    }

    /// From the farm's own envelopes, so `INTERNAL`, which arrives as a `.rejected` like the
    /// refusals do, stays retryable.
    func testOnlyWhatTheFarmWillNeverAcceptIsDropped() {
        XCTAssertEqual(disposition(status: 422, code: "VALIDATION_ERROR"), .drop)
        XCTAssertEqual(disposition(status: 422, code: "UNSUPPORTED_FORMAT"), .drop)
        XCTAssertEqual(disposition(status: 404, code: "NOT_FOUND"), .drop)
        XCTAssertEqual(disposition(status: 409, code: "SOURCE_ALREADY_CLAIMED"), .drop)
        XCTAssertEqual(disposition(status: 403, code: "ACCOUNT_BLOCKED"), .drop)
        XCTAssertEqual(ContributionOutbox.disposition(of: PoseEncodingError()), .drop)

        XCTAssertEqual(disposition(status: 500, code: "INTERNAL"), .retry(after: nil))
        XCTAssertEqual(disposition(status: 422, code: "BLOB_MISSING"), .retry(after: nil))
        XCTAssertEqual(disposition(status: 422, code: "BLOB_DIGEST_MISMATCH"), .retry(after: nil))
        XCTAssertEqual(disposition(status: 503, code: "APPLE_UNAVAILABLE"), .retry(after: nil))
        XCTAssertEqual(ContributionOutbox.disposition(of: FarmError.http(status: 403)), .retry(after: nil))
        XCTAssertEqual(ContributionOutbox.disposition(of: URLError(.notConnectedToInternet)), .retry(after: nil))
        XCTAssertEqual(ContributionOutbox.disposition(of: CancellationError()), .retry(after: nil))

        XCTAssertEqual(disposition(status: 401, code: "UNAUTHENTICATED"), .signIn)
    }

    func testARefusedJobIsDroppedAndTheNextStillGoes() async {
        let farm = ScriptedFarm([Self.refusal(422, "VALIDATION_ERROR")] + Self.delivered(Self.otherVideoID))
        let store = ContributionOutboxStore(directory: directory)
        await store.write(OutboxJob(id: UUID(), enqueuedAt: Date(timeIntervalSinceNow: -60), source: Self.source()))
        await store.write(OutboxJob(id: UUID(), enqueuedAt: Date(), source: Self.source(Self.otherVideoID)))

        let outbox = outbox(account(client: farm.client))
        outbox.resume()
        await settled(outbox)

        XCTAssertEqual(farm.calls.count, 4)
        XCTAssertTrue(outbox.jobs.isEmpty)
        XCTAssertEqual(filesOnDisk(), [])
        XCTAssertEqual(waits.delays, [])
    }

    // MARK: - Sessions and consent

    /// A `401` signs the app out and leaves the job for the next sign-in, which sends it.
    func testAnExpiredSessionWaitsForTheNextSignIn() async {
        let farm = ScriptedFarm([Self.refusal(401, "UNAUTHENTICATED")])
        let account = account(client: farm.client)
        let outbox = outbox(account)

        await outbox.enqueue(Self.source())
        await settled(outbox)

        XCTAssertFalse(account.isSignedIn)
        XCTAssertEqual(outbox.jobs.count, 1)
        XCTAssertEqual(filesOnDisk().count, 1)
        XCTAssertEqual(waits.delays, [], "nothing to retry until someone signs in")

        farm.script(Self.delivered())
        account.signedIn(sessionToken: "fresh", appleUserID: "user-1")
        await eventually("the job leaves the queue") { outbox.jobs.isEmpty }

        XCTAssertEqual(farm.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    /// A `401` for a session already replaced says nothing about the one now held, so the job
    /// tries again under it.
    func testALate401DoesNotEndANewerSession() async {
        let farm = ScriptedFarm([Self.refusal(401, "UNAUTHENTICATED")])
        let credentials = FarmCredentials(store: MemorySecrets())
        credentials.signedIn(sessionToken: "old", appleUserID: "user-1")
        credentials.recordConsent()
        let client = FarmClient(baseURL: URL(string: "https://farm.test")!) { request in
            credentials.signedIn(sessionToken: "new", appleUserID: "user-1")
            return try await farm.client.transport(request)
        }
        let account = FarmAccount(client: client, credentials: credentials)
        let outbox = outbox(account)

        await outbox.enqueue(Self.source())
        await eventually("a retry wait") { waits.delays == [30] }
        XCTAssertTrue(account.isSignedIn)
        XCTAssertEqual(credentials.sessionToken, "new")

        outbox.resume()
        await eventually("a try under the new session") { farm.requests.count == 2 }
        XCTAssertEqual(farm.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
    }

    /// A stopped upload can take a moment to unwind. A resume landing in that moment isn't lost.
    func testAResumeDuringAStopStillSends() async {
        let farm = ScriptedFarm([])
        let reached = Latch()
        let released = Latch()
        let credentials = FarmCredentials(store: MemorySecrets())
        credentials.signedIn(sessionToken: "tok", appleUserID: "user-1")
        credentials.recordConsent()
        let client = FarmClient(baseURL: URL(string: "https://farm.test")!) { request in
            reached.set()
            while !released.isSet { await Task.yield() }
            return try await farm.client.transport(request)
        }
        let account = FarmAccount(client: client, credentials: credentials)
        let outbox = outbox(account)
        await outbox.enqueue(Self.source())
        await eventually("an upload under way") { reached.isSet }

        account.sessionEnded()
        try? await Task.sleep(nanoseconds: 20_000_000)
        account.signedIn(sessionToken: "tok", appleUserID: "user-1")
        try? await Task.sleep(nanoseconds: 20_000_000)
        farm.script([Self.refusal(500, "INTERNAL")] + Self.delivered())
        released.set()
        await eventually("the job leaves the queue") { outbox.jobs.isEmpty }
        await settled(outbox)

        XCTAssertEqual(farm.calls.count, 4, "the stopped attempt failed, so a second one delivered it")
        XCTAssertEqual(filesOnDisk(), [])
    }

    func testNothingGoesForAnAccountThatHasNotAgreed() async {
        let farm = ScriptedFarm([])
        let account = account(client: farm.client, signedInAs: "user-2", consentedAs: "user-1")
        let outbox = outbox(account)

        await outbox.enqueue(Self.source())
        await settled(outbox)

        XCTAssertEqual(farm.calls, [])
        XCTAssertEqual(outbox.jobs.count, 1)
    }

    func testSigningOutPausesAnUploadAndKeepsTheJob() async {
        let reached = Latch()
        let credentials = FarmCredentials(store: MemorySecrets())
        credentials.signedIn(sessionToken: "tok", appleUserID: "user-1")
        credentials.recordConsent()
        let account = FarmAccount(client: Self.stalledClient(reached: reached), credentials: credentials)
        let outbox = outbox(account)
        await outbox.enqueue(Self.source())
        await eventually("an upload under way") { reached.isSet }

        account.sessionEnded()
        await eventually("the upload stops") { outbox.drain == nil }

        XCTAssertEqual(outbox.jobs.count, 1)
        XCTAssertEqual(filesOnDisk().count, 1)
    }

    // MARK: - Withdrawing

    /// Off means off: the upload under way stops and nothing queued survives, on disk included.
    func testTurningTheSwitchOffCancelsEverything() async {
        let reached = Latch()
        let credentials = FarmCredentials(store: MemorySecrets())
        credentials.signedIn(sessionToken: "tok", appleUserID: "user-1")
        credentials.recordConsent()
        let settings = settings()
        let account = FarmAccount(client: Self.stalledClient(reached: reached), credentials: credentials)
        let outbox = outbox(account, settings: settings)
        await outbox.enqueue(Self.source())
        await eventually("an upload under way") { reached.isSet }

        settings.contributesClips = false
        await eventually("the queue empties, on disk too") {
            outbox.jobs.isEmpty && outbox.drain == nil && filesOnDisk().isEmpty
        }
    }

    /// Turning the switch off cancels what's queued, so this reaches the gate itself: a job queued
    /// with the switch already off, as a save racing the switch could do.
    func testNothingGoesWhileTheSwitchIsOff() async {
        let farm = ScriptedFarm([])
        let outbox = outbox(account(client: farm.client), settings: settings(contributes: false))
        await outbox.cancelAll()

        await outbox.enqueue(Self.source())
        await settled(outbox)

        XCTAssertEqual(farm.calls, [])
    }

    func testAQueueFoundWithTheSwitchOffIsCleared() async {
        let store = ContributionOutboxStore(directory: directory)
        await store.write(OutboxJob(id: UUID(), enqueuedAt: Date(), source: Self.source()))
        let farm = ScriptedFarm([])

        _ = outbox(account(client: farm.client), settings: settings(contributes: false))

        await eventually("the file goes") { filesOnDisk().isEmpty }
        XCTAssertEqual(farm.calls, [])
    }

    /// Nothing queued may reach the farm once deletion starts, and the next account is asked
    /// afresh. The upload under way stops first, so the source it may have registered is then
    /// deleted with the rest, by the key it minted.
    func testDeletingTheAccountStopsTheQueueThenDeletes() async throws {
        let farm = ScriptedFarm([.init(status: 204, body: ""), .init(status: 204, body: "")])
        let reached = Latch()
        let credentials = FarmCredentials(store: MemorySecrets())
        credentials.signedIn(sessionToken: "tok", appleUserID: "user-1")
        credentials.recordConsent()
        let client = FarmClient(baseURL: URL(string: "https://farm.test")!) { request in
            if request.url?.path == "/api/sources" {
                reached.set()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return try await farm.client.transport(request)
        }
        let account = FarmAccount(client: client, credentials: credentials)
        let outbox = outbox(account)
        await outbox.enqueue(Self.source())
        await eventually("an upload under way") { reached.isSet }

        try await outbox.deleteAccount()

        XCTAssertEqual(farm.calls, ["DELETE /api/sources/\(Self.videoID)", "DELETE /api/account"])
        XCTAssertTrue(outbox.jobs.isEmpty)
        XCTAssertEqual(filesOnDisk(), [])
        XCTAssertFalse(credentials.hasConsented)
        XCTAssertFalse(account.isSignedIn)
    }

    /// A cancelled request can still be on the wire, and it may be the one registering a source.
    /// Deleting before it has finished could miss what it creates, and a foreground landing in
    /// that wait must not start the job over.
    func testDeletionWaitsForAnUploadStillOnTheWire() async throws {
        let farm = ScriptedFarm([
            Self.refusal(500, "INTERNAL"), .init(status: 204, body: ""), .init(status: 204, body: "")
        ])
        let reached = Latch()
        let released = Latch()
        let credentials = FarmCredentials(store: MemorySecrets())
        credentials.signedIn(sessionToken: "tok", appleUserID: "user-1")
        credentials.recordConsent()
        let client = FarmClient(baseURL: URL(string: "https://farm.test")!) { request in
            if request.url?.path == "/api/sources" {
                reached.set()
                while !released.isSet { await Task.yield() }
            }
            return try await farm.client.transport(request)
        }
        let outbox = outbox(FarmAccount(client: client, credentials: credentials))
        await outbox.enqueue(Self.source())
        await eventually("an upload under way") { reached.isSet }

        let deletion = Task { try await outbox.deleteAccount() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(farm.calls, [], "a delete went out with the upload still running")

        outbox.resume()
        released.set()
        try await deletion.value

        XCTAssertEqual(farm.calls, [
            "POST /api/sources", "DELETE /api/sources/\(Self.videoID)", "DELETE /api/account"
        ])
    }

    // MARK: - Clips that changed while waiting

    private func sentClips(_ farm: ScriptedFarm) throws -> [[String: Any]] {
        let request = try XCTUnwrap(farm.requests.first { $0.url?.path == "/api/clips" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        return try XCTUnwrap(body["clips"] as? [[String: Any]])
    }

    func testAClipRemovedWhileWaitingStaysHere() async throws {
        let farm = ScriptedFarm(Self.delivered(Self.videoID, [Self.otherClipID]))
        let outbox = outbox(account(client: farm.client), savedClip: { id in
            id == Self.clipID ? nil : Self.saved(id, names: Self.cork)
        })

        await outbox.enqueue(Self.source(clips: [Self.clip(), Self.clip(Self.otherClipID)]))
        await settled(outbox)

        XCTAssertEqual(try sentClips(farm).map { $0["clip_id"] as? String }, [Self.otherClipID.uuidString.lowercased()])
        XCTAssertTrue(outbox.jobs.isEmpty)
    }

    func testAJobWithNoClipLeftGoesWithoutASingleCall() async {
        let farm = ScriptedFarm([])
        let outbox = outbox(account(client: farm.client), savedClip: { _ in nil })

        await outbox.enqueue(Self.source())
        await settled(outbox)

        XCTAssertEqual(farm.calls, [])
        XCTAssertTrue(outbox.jobs.isEmpty)
        XCTAssertEqual(filesOnDisk(), [])
    }

    func testAClipRenamedWhileWaitingGoesWithItsNewNames() async throws {
        let renamed = [ClipName(name: "gainer", origin: .vocabulary)]
        let farm = ScriptedFarm([Self.registered(), Self.clipsTaken, Self.readBack(names: "gainer")])
        let outbox = outbox(account(client: farm.client), savedClip: { Self.saved($0, names: renamed) })

        await outbox.enqueue(Self.source())
        await settled(outbox)

        let labels = try XCTUnwrap(try sentClips(farm).first?["labels"] as? [[String: String]])
        XCTAssertEqual(labels, [["name": "gainer", "origin": "vocabulary"]])
        XCTAssertTrue(outbox.jobs.isEmpty)
    }

    // MARK: - Store

    func testAJobComesBackFromDiskExactlyAsWritten() async {
        let proposed = ClipContribution(
            clipID: Self.clipID, window: TrickWindow(startTime: 1.25, endTime: 2.5), autoDetected: false,
            names: [ClipName(name: "cork", origin: .model)],
            proposal: ModelProposal(modelVersion: "trick-v1", suggestedNames: ["cork"], suggestionsWithheld: false))
        let slots: [[Float]?] = [Array(repeating: 0.1, count: 51), nil, Array(repeating: -1.2345678, count: 51)]
        let job = OutboxJob(
            id: UUID(), enqueuedAt: Date(timeIntervalSinceReferenceDate: 12_345),
            source: SourceContribution(
                videoID: Self.videoID, pose: ContributionPose(sampleRate: 29.97, slots: slots), clips: [proposed]))
        let store = ContributionOutboxStore(directory: directory)

        await store.write(job)
        let loaded = await store.load()

        XCTAssertEqual(loaded, [job])
    }

    /// The pose is written unclamped, so a non-finite value has to survive the file too.
    func testAJobWithANonFiniteKeypointIsStillKept() async throws {
        let slot = [Float.nan, .infinity, -.infinity] + Array(repeating: Float(0.5), count: 48)
        let job = OutboxJob(
            id: UUID(), enqueuedAt: Date(),
            source: SourceContribution(
                videoID: Self.videoID, pose: ContributionPose(sampleRate: 10, slots: [slot]), clips: [Self.clip()]))
        let store = ContributionOutboxStore(directory: directory)

        await store.write(job)
        let loaded = await store.load()

        let values = try XCTUnwrap(loaded.first?.source.pose.slots.first ?? nil)
        XCTAssertTrue(values[0].isNaN)
        XCTAssertEqual(values[1], .infinity)
        XCTAssertEqual(values[2], -.infinity)
    }

    func testAnUnreadableFileIsRemovedAndTheRestStillLoad() async throws {
        let store = ContributionOutboxStore(directory: directory)
        let job = OutboxJob(id: UUID(), enqueuedAt: Date(timeIntervalSinceReferenceDate: 1), source: Self.source())
        await store.write(job)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))

        let loaded = await store.load()

        XCTAssertEqual(loaded, [job])
        XCTAssertEqual(filesOnDisk().count, 1)
    }

    func testTheQueueStaysOutOfDeviceBackups() async throws {
        let store = ContributionOutboxStore(directory: directory)
        await store.write(OutboxJob(id: UUID(), enqueuedAt: Date(), source: Self.source()))

        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testWaitingClipsCountAcrossJobs() async {
        let farm = ScriptedFarm([])
        let outbox = outbox(account(client: farm.client, signedInAs: nil))

        await outbox.enqueue(Self.source(clips: [Self.clip(), Self.clip(Self.otherClipID)]))
        await outbox.enqueue(Self.source(Self.otherVideoID))

        XCTAssertEqual(outbox.waitingClipCount, 3)
    }
}
