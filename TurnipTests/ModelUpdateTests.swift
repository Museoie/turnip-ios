import CryptoKit
import XCTest
@testable import Turnip

/// Mock for `ModelUpdateClient`: feeds the service a canned manifest and canned
/// bytes without touching the network — unit tests must never depend on a farm
/// deployment being reachable.
actor MockModelUpdateClient: ModelUpdateClient {
    /// The manifest's JSON as the farm serves it; `nil` answers as the farm
    /// does before its first promotion.
    var manifest: Data?
    var manifestError: Error?
    var downloadBytes: Data?
    var downloadError: Error?

    private(set) var fetchedEndpoints: [URL] = []
    private(set) var downloadRequests: [URL] = []

    /// One-shot gate for `downloadModel`: when armed via
    /// `armDownloadSuspension()`, the next download call records its request
    /// and then parks on a continuation instead of completing, until the test
    /// calls `releaseDownloadSuspension()`. This holds the service's
    /// in-flight window open so a test can make a second check provably
    /// overlap the first — structural overlap, not scheduling luck. See
    /// `testOverlappingChecksAreSuppressed`.
    var suspendNextDownload = false
    private var suspendedDownload: CheckedContinuation<Void, Never>?

    func fetchManifest(from endpoint: URL) async throws -> Data? {
        fetchedEndpoints.append(endpoint)
        if let manifestError = manifestError {
            throw manifestError
        }
        return manifest
    }

    func downloadModel(from url: URL) async throws -> URL {
        downloadRequests.append(url)
        if suspendNextDownload {
            suspendNextDownload = false
            await withCheckedContinuation { continuation in
                suspendedDownload = continuation
            }
        }
        if let downloadError = downloadError {
            throw downloadError
        }
        let bytes = try XCTUnwrap(downloadBytes, "mock download bytes not configured")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url, options: .atomic)
        return url
    }
}

/// The manifest turnip-farm's `GET /api/models/current` serves, written out
/// literally in the shape of `MODEL_CONTRACT.md` §1 and the farm's
/// `handleGetModelsCurrent`, keys in its order.
enum FarmManifestFixture {
    /// The SHA-256 the manifest carries for `artifact`.
    static func sha256Hex(_ artifact: Data) -> String {
        SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
    }

    /// - Parameters:
    ///   - byteSize: the `byte_size` served; `.some(nil)` serves `null`, and
    ///     the default serves the artifact's true length.
    ///   - jsonbAsStrings: serves the four JSONB fields as JSON strings, as
    ///     the farm's `JSON.stringify(x)::jsonb` insert may store them.
    static func json(
        version: String,
        artifact: Data,
        byteSize: Int?? = .none,
        minClientVersion: String? = nil,
        jsonbAsStrings: Bool = false
    ) -> Data {
        let size = byteSize.map { $0.map(String.init) ?? "null" } ?? String(artifact.count)
        let minimum = minClientVersion.map { "\"\($0)\"" } ?? "null"
        let inputDesc = #"""
        {"format": "TKP1", "format_version": 1, "sample_rate_hz": 10.0, "keypoint_count": 17,
         "features": ["x", "y", "confidence", "gap_indicator"], "input_name": "pose",
         "shape": ["T", 52], "min_frames": 16, "max_frames": 144000}
        """#
        let outputDesc = #"""
        {"coordinates": "source-frame", "kind": "window_classifier", "output_name": "window_probs",
         "shape": ["N", 4], "window_frames": 16, "window_stride": 8,
         "classes": ["background", "cork", "cork+gainer", "gainer"],
         "background_class": "background", "combo_separator": "+",
         "embedding": {"output_name": "window_embeddings", "shape": ["N", 68],
                       "window_frames": 16, "window_stride": 8}}
        """#
        let valMetrics = #"{"val_accuracy": 0.91, "n_val_windows": 5120}"#
        let nameMetrics = #"""
        {"cork": {"precision": 0.88, "recall": 0.79, "holdout_count": 24, "train_count": 310},
         "gainer": {"precision": null, "recall": null, "holdout_count": 2, "train_count": 41}}
        """#
        // The objects hold no backslashes, so quoting them escapes only their quotes.
        let jsonb = { (object: String) -> String in
            guard jsonbAsStrings else { return object }
            let compact = object.split(separator: "\n").joined(separator: " ")
            return "\"" + compact.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return Data(#"""
        {
          "version": "\#(version)",
          "model_type": "trick-detection",
          "taxonomy_version": 7,
          "r2_key": "models/\#(version).mlpackage.zip",
          "url": "https://r2.example.com/models/\#(version).mlpackage.zip?X-Amz-Expires=900&X-Amz-Signature=ab12",
          "sha256": "\#(sha256Hex(artifact))",
          "byte_size": \#(size),
          "min_client_version": \#(minimum),
          "input_desc": \#(jsonb(inputDesc)),
          "output_desc": \#(jsonb(outputDesc)),
          "holdout_report_r2_key": "reports/\#(version)-holdout.json",
          "training_run_id": "nightly-2026-10-07",
          "val_metrics": \#(jsonb(valMetrics)),
          "name_metrics": \#(jsonb(nameMetrics)),
          "vocabulary": [
            {"canonical": "cork", "aliases": ["cork", "cork 720", "corkscrew"]},
            {"canonical": "gainer", "aliases": ["gainer", "moon kick"]}
          ],
          "promoted_at": "2026-10-07T07:12:00.000Z"
        }
        """#.utf8)
    }

    /// The presigned URL `json` serves for `version`.
    static func url(version: String) -> URL {
        URL(string: "https://r2.example.com/models/\(version).mlpackage.zip?X-Amz-Expires=900&X-Amz-Signature=ab12")!
    }
}

final class ModelUpdateTests: XCTestCase {

    // MARK: - Helpers

    private let artifact = Data("fake-model-bytes".utf8)

    private func makeStore() -> ModelUpdateStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelUpdateTests-\(UUID().uuidString)", isDirectory: true)
        return ModelUpdateStore(baseURL: dir)
    }

    private func makeService(
        client: MockModelUpdateClient,
        store: ModelUpdateStore,
        baseURL: URL? = URL(string: "https://farm.example.com")!,
        clientVersion: String? = "1.1"
    ) -> ModelUpdateService<MockModelUpdateClient> {
        ModelUpdateService(baseURL: baseURL, client: client, store: store, clientVersion: clientVersion)
    }

    private func manifest(_ version: String, artifact: Data? = nil) throws -> ModelUpdateManifest {
        try ModelUpdateManifest(json: FarmManifestFixture.json(version: version, artifact: artifact ?? self.artifact))
    }

    /// The store's directory, by file name.
    private func files(in store: ModelUpdateStore) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: store.baseURL.path)) ?? [])
    }

    /// Runs one check against a manifest for `version` serving `artifact`.
    private func check(
        _ version: String,
        store: ModelUpdateStore,
        client: MockModelUpdateClient = MockModelUpdateClient()
    ) async -> ModelUpdateError? {
        await client.setManifest(FarmManifestFixture.json(version: version, artifact: artifact))
        await client.setDownloadBytes(artifact)
        let service = makeService(client: client, store: store)
        await service.checkForUpdates()
        return await service.lastError
    }

    // MARK: - Manifest

    /// The manifest decodes from the farm's exact JSON, and keeps that JSON
    /// whole for whatever reads its other fields later.
    func testManifestDecodesTheFarmsManifest() throws {
        let json = FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact, minClientVersion: "0.2.0")
        let manifest = try ModelUpdateManifest(json: json)
        XCTAssertEqual(manifest.version, ModelVersion("trick-v1.3"))
        XCTAssertEqual(manifest.url, FarmManifestFixture.url(version: "trick-v1.3"))
        XCTAssertEqual(manifest.sha256, FarmManifestFixture.sha256Hex(artifact))
        XCTAssertEqual(manifest.byteSize, artifact.count)
        XCTAssertEqual(manifest.minClientVersion, "0.2.0")
        XCTAssertEqual(manifest.json, json)
    }

    /// `byte_size` and `min_client_version` are nullable farm columns.
    func testManifestDecodesNullByteSizeAndMinimum() throws {
        let manifest = try ModelUpdateManifest(
            json: FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact, byteSize: .some(nil)))
        XCTAssertNil(manifest.byteSize)
        XCTAssertNil(manifest.minClientVersion)
    }

    /// The farm's JSONB fields may arrive as JSON strings rather than objects;
    /// the manifest doesn't depend on them, so it decodes either way.
    func testManifestDecodesWhenTheJSONBFieldsAreStrings() throws {
        let json = FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact, jsonbAsStrings: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertTrue(object["output_desc"] is String, "test setup: output_desc served as a string")
        XCTAssertEqual(try ModelUpdateManifest(json: json).version, ModelVersion("trick-v1.3"))
    }

    /// The pre-contract shape (`downloadURL`, `fileName`) and a manifest
    /// without its `url` are invalid, not network failures.
    func testManifestWithoutTheFieldsTheUpdateNeedsIsInvalid() {
        let preContract = Data("""
        {"version": "2026.09.10-1", "downloadURL": "https://models.example.com/m.zip",
         "sha256": "abc123", "fileName": "m.zip"}
        """.utf8)
        let noURL = Data(#"{"version": "trick-v1.3", "sha256": "abc123", "byte_size": 4}"#.utf8)
        for json in [preContract, noURL, Data("not json".utf8)] {
            XCTAssertThrowsError(try ModelUpdateManifest(json: json)) { error in
                guard case .invalidManifest? = error as? ModelUpdateError else {
                    return XCTFail("expected invalidManifest, got \(error)")
                }
            }
        }
    }

    /// `min_client_version` against the app's `CFBundleShortVersionString`,
    /// compared as dotted numbers; anything that isn't one can't be shown to
    /// be compatible, so it doesn't admit the app.
    func testMinClientVersionAdmitsOnlyAppsAtLeastIt() throws {
        let admitted: [(minimum: String?, client: String?)] = [
            (nil, "1.1"), (nil, nil), ("0.2.0", "1.1"), ("1.1", "1.1"), ("1.1.0", "1.1"), ("1.1", "1.1.0"),
            ("1.9", "1.10")
        ]
        let refused: [(minimum: String?, client: String?)] = [
            ("1.1.1", "1.1"), ("2.4.0", "1.1"), ("1.10", "1.9"), ("v1", "1.1"), ("1..1", "1.1"), ("+1", "2"),
            ("1.1", nil), ("1.1", ""), ("1.1", "1.1 beta")
        ]
        for (pairs, admits) in [(admitted, true), (refused, false)] {
            for (minimum, client) in pairs {
                let json = FarmManifestFixture.json(
                    version: "trick-v1.3", artifact: artifact, minClientVersion: minimum)
                XCTAssertEqual(
                    try ModelUpdateManifest(json: json).admits(clientVersion: client), admits,
                    "minimum \(minimum ?? "null"), app \(client ?? "nil")")
            }
        }
    }

    /// The version names the store's files: farm versions pass; anything that
    /// could leave the directory, hide the file or pass as a lookalike doesn't.
    func testOnlyFileSafeVersionsAreValid() {
        for valid in ["trick-v1.3", "trick-v1.3-rb1", "trick-v0.0-smoke", "2026.09.10-1"] {
            XCTAssertNoThrow(try ModelUpdateStore.validate(version: ModelVersion(valid)), valid)
        }
        for invalid in ["", ".", "..", ".hidden", "../evil", "models/trick-v1.3", "trick v1.3", "мodel"] {
            XCTAssertThrowsError(try ModelUpdateStore.validate(version: ModelVersion(invalid)), invalid)
        }
    }

    // MARK: - Service

    /// The whole path for a manifest exactly as the farm serves it: the model
    /// downloads from its presigned `url`, is checked against its `byte_size`
    /// and `sha256`, and waits as the pending model under files named for its
    /// version, its manifest kept beside it. Nothing is named after `r2_key`.
    func testAFarmManifestStagesItsModelEndToEnd() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let json = FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact, minClientVersion: "0.2.0")
        await client.setManifest(json)
        await client.setDownloadBytes(artifact)

        let service = makeService(client: client, store: store)
        await service.checkForUpdates()

        let lastError = await service.lastError
        XCTAssertNil(lastError)
        let fetched = await client.fetchedEndpoints
        XCTAssertEqual(fetched, [URL(string: "https://farm.example.com/api/models/current")!])
        let downloads = await client.downloadRequests
        XCTAssertEqual(downloads, [FarmManifestFixture.url(version: "trick-v1.3")])

        let pending = try XCTUnwrap(store.pendingModel())
        XCTAssertEqual(pending.version, ModelVersion("trick-v1.3"))
        XCTAssertEqual(try Data(contentsOf: pending.artifactURL), artifact)
        XCTAssertEqual(try Data(contentsOf: pending.manifestURL), json)
        XCTAssertNil(store.activeModel(), "nothing is active until the loader has loaded it")
        XCTAssertEqual(
            files(in: store),
            ["staged-models.json", "trick-v1.3.mlpackage.zip", "trick-v1.3.manifest.json"])
    }

    /// The farm's JSONB fields served as strings still stage the model.
    func testAManifestWithJSONBFieldsAsStringsStillStages() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        await client.setManifest(
            FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact, jsonbAsStrings: true))
        await client.setDownloadBytes(artifact)
        await makeService(client: client, store: store).checkForUpdates()
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.3"))
    }

    /// The previous model stays until the new one loads (`MODEL_CONTRACT.md`
    /// §4): staging leaves the active model and its files alone, and only the
    /// loader's report of a successful load retires them.
    func testANewModelKeepsTheActiveOneUntilItLoads() async throws {
        let store = makeStore()
        let firstError = await check("trick-v1.2", store: store)
        XCTAssertNil(firstError)
        store.markLoaded(ModelVersion("trick-v1.2"))
        let previous = try XCTUnwrap(store.activeModel())

        let secondError = await check("trick-v1.3", store: store)
        XCTAssertNil(secondError)
        XCTAssertEqual(store.activeModel(), previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.artifactURL.path))
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.3"))

        store.markLoaded(ModelVersion("trick-v1.3"))
        XCTAssertEqual(store.activeModel()?.version, ModelVersion("trick-v1.3"))
        XCTAssertNil(store.pendingModel())
        XCTAssertEqual(
            files(in: store),
            ["staged-models.json", "trick-v1.3.mlpackage.zip", "trick-v1.3.manifest.json"])
    }

    /// A model that doesn't load is deleted and the active one kept; the next
    /// poll fetches it again, as the contract's failure fallback asks.
    func testAModelThatDoesntLoadIsDiscardedAndRetriedOnTheNextPoll() async throws {
        let store = makeStore()
        _ = await check("trick-v1.2", store: store)
        store.markLoaded(ModelVersion("trick-v1.2"))
        let client = MockModelUpdateClient()
        _ = await check("trick-v1.3", store: store, client: client)

        store.discard(ModelVersion("trick-v1.3"))
        XCTAssertNil(store.pendingModel())
        XCTAssertEqual(store.activeModel()?.version, ModelVersion("trick-v1.2"))
        XCTAssertEqual(
            files(in: store),
            ["staged-models.json", "trick-v1.2.mlpackage.zip", "trick-v1.2.manifest.json"])

        _ = await check("trick-v1.3", store: store, client: client)
        let downloads = await client.downloadRequests
        XCTAssertEqual(downloads.count, 2)
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.3"))
    }

    /// A version the store already has, active or pending, isn't downloaded
    /// again: the check stays a cheap manifest fetch on every launch.
    func testAVersionAlreadyStagedIsNotDownloadedAgain() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        _ = await check("trick-v1.3", store: store, client: client)
        _ = await check("trick-v1.3", store: store, client: client)
        var downloads = await client.downloadRequests
        XCTAssertEqual(downloads.count, 1, "pending")

        store.markLoaded(ModelVersion("trick-v1.3"))
        _ = await check("trick-v1.3", store: store, client: client)
        downloads = await client.downloadRequests
        XCTAssertEqual(downloads.count, 1, "active")
    }

    /// Updating means a different version, not a greater one: a rollback's
    /// `-rb1` version and a lower-looking one both download.
    func testAnyDifferentVersionIsAnUpdate() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        _ = await check("trick-v1.3", store: store, client: client)
        store.markLoaded(ModelVersion("trick-v1.3"))

        _ = await check("trick-v1.3-rb1", store: store, client: client)
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.3-rb1"))
        _ = await check("trick-v1.2", store: store, client: client)
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.2"))
        let downloads = await client.downloadRequests
        XCTAssertEqual(downloads.count, 3)
        XCTAssertFalse(files(in: store).contains("trick-v1.3-rb1.mlpackage.zip"), "the replaced pending model")
    }

    /// A manifest naming the active model again means a model staged since is
    /// no longer current: it is dropped, and nothing downloads.
    func testAManifestNamingTheActiveModelDropsThePendingOne() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        _ = await check("trick-v1.2", store: store, client: client)
        store.markLoaded(ModelVersion("trick-v1.2"))
        _ = await check("trick-v1.3", store: store, client: client)

        _ = await check("trick-v1.2", store: store, client: client)
        XCTAssertNil(store.pendingModel())
        XCTAssertEqual(store.activeModel()?.version, ModelVersion("trick-v1.2"))
        let downloads = await client.downloadRequests
        XCTAssertEqual(downloads.count, 2)
    }

    /// An app older than `min_client_version` skips the model silently: no
    /// download, nothing staged, and no failure recorded. A model meant for
    /// it downloads.
    func testAnAppTooOldForTheModelSkipsItSilently() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        await client.setManifest(
            FarmManifestFixture.json(version: "trick-v2.0", artifact: artifact, minClientVersion: "2.4.0"))
        await client.setDownloadBytes(artifact)
        let service = makeService(client: client, store: store, clientVersion: "1.1")
        await service.checkForUpdates()

        let skippedError = await service.lastError
        XCTAssertNil(skippedError)
        var downloads = await client.downloadRequests
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertNil(store.pendingModel())

        await client.setManifest(
            FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact, minClientVersion: "1.1"))
        await service.checkForUpdates()
        downloads = await client.downloadRequests
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.3"))
    }

    /// Bytes of the wrong length fail on `byte_size` and stage nothing.
    func testByteSizeMismatchStagesNothing() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        await client.setManifest(
            FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact, byteSize: artifact.count + 1))
        await client.setDownloadBytes(artifact)
        let service = makeService(client: client, store: store)
        await service.checkForUpdates()

        XCTAssertNil(store.pendingModel())
        XCTAssertTrue(files(in: store).isEmpty)
        let lastError = await service.lastError
        guard case .sizeMismatch? = lastError else {
            return XCTFail("expected sizeMismatch, got \(String(describing: lastError))")
        }
    }

    /// With no `byte_size`, the checksum alone vouches for the bytes.
    func testANullByteSizeChecksOnlyTheChecksum() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        await client.setManifest(
            FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact, byteSize: .some(nil)))
        await client.setDownloadBytes(artifact)
        await makeService(client: client, store: store).checkForUpdates()
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.3"))
    }

    /// Corrupt bytes must fail the checksum and stage nothing — the guard the
    /// whole "never break the app" contract rests on, so the bytes are the
    /// right length and deliberately don't match the manifest hash.
    func testCheckForUpdatesRejectsChecksumMismatch() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        await client.setManifest(FarmManifestFixture.json(version: "trick-v1.3", artifact: Data("real-bytes".utf8)))
        await client.setDownloadBytes(Data("fake-bytes".utf8))

        let service = makeService(client: client, store: store)
        await service.checkForUpdates() // must not throw

        XCTAssertNil(store.pendingModel())
        XCTAssertNil(store.activeModel())
        let lastError = await service.lastError
        guard case .checksumMismatch? = lastError else {
            return XCTFail("expected checksumMismatch, got \(String(describing: lastError))")
        }
    }

    /// Any client failure surfaces as a swallowed error, never a throw — and a
    /// failed update must not disturb the models already staged.
    func testCheckForUpdatesFailsSilently() async throws {
        let store = makeStore()
        _ = await check("trick-v1.2", store: store)
        store.markLoaded(ModelVersion("trick-v1.2"))
        let client = MockModelUpdateClient()
        await client.setManifest(FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact))
        await client.setManifestError(ModelUpdateError.network(underlying: "offline"))
        let service = makeService(client: client, store: store)
        await service.checkForUpdates() // must not throw

        let active = try XCTUnwrap(store.activeModel())
        XCTAssertEqual(active.version, ModelVersion("trick-v1.2"))
        XCTAssertEqual(try Data(contentsOf: active.artifactURL), artifact)
        XCTAssertNil(store.pendingModel())
        let lastError = await service.lastError
        XCTAssertNotNil(lastError)
    }

    /// A manifest that doesn't decode is invalid, and nothing downloads.
    func testAnUndecodableManifestIsInvalidBeforeDownload() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        await client.setManifest(Data(#"{"version": "2026.09.10-1", "downloadURL": "https://x.example/m"}"#.utf8))
        await client.setDownloadBytes(artifact)
        let service = makeService(client: client, store: store)
        await service.checkForUpdates()

        let downloads = await client.downloadRequests
        XCTAssertTrue(downloads.isEmpty)
        let lastError = await service.lastError
        guard case .invalidManifest? = lastError else {
            return XCTFail("expected invalidManifest, got \(String(describing: lastError))")
        }
    }

    /// A version that can't name a file in the store is refused before any
    /// bytes move, and nothing is written.
    func testAnUnsafeVersionIsRejectedBeforeDownload() async throws {
        for version in ["../evil", "models/trick-v1.3", "мodel"] {
            let store = makeStore()
            let client = MockModelUpdateClient()
            let error = await check(version, store: store, client: client)
            guard case .invalidManifest? = error else {
                return XCTFail("expected invalidManifest for \(version), got \(String(describing: error))")
            }
            let downloads = await client.downloadRequests
            XCTAssertTrue(downloads.isEmpty, version)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.baseURL.path), version)
        }
    }

    /// Before the farm's first promotion there is nothing to fetch: no
    /// download, and no failure recorded.
    func testNoModelPublishedIsNotAFailure() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let service = makeService(client: client, store: store)
        await service.checkForUpdates()

        let fetched = await client.fetchedEndpoints
        XCTAssertEqual(fetched.count, 1)
        let downloads = await client.downloadRequests
        XCTAssertTrue(downloads.isEmpty)
        let lastError = await service.lastError
        XCTAssertNil(lastError)
    }

    /// A cancelled check is a deliberate stop, not a failed update: a
    /// `CancellationError` thrown mid-check must not be recorded on
    /// `lastError` where it would be misreported as an update failure — boxing
    /// it into `.network(underlying:)` would fail this.
    func testCheckForUpdatesIgnoresCancellationError() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        await client.setManifest(FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact))
        await client.setManifestError(CancellationError())

        let service = makeService(client: client, store: store)
        await service.checkForUpdates() // must not throw

        let lastError = await service.lastError
        XCTAssertNil(lastError)
    }

    /// No configured endpoint means no network at all — the service is inert
    /// until the endpoint is set.
    func testCheckForUpdatesIsNoOpWithoutEndpoint() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let service = makeService(client: client, store: store, baseURL: nil)
        await service.checkForUpdates()
        let fetched = await client.fetchedEndpoints
        XCTAssertTrue(fetched.isEmpty)
        let lastError = await service.lastError
        XCTAssertNil(lastError)
    }

    /// Two overlapping checks must not both hit the network: the second is
    /// suppressed while the first is in flight, so one foreground-bounce
    /// costs a single manifest fetch instead of two downloads racing.
    func testOverlappingChecksAreSuppressed() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        await client.setManifest(FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact))
        await client.setDownloadBytes(artifact)
        // Park the first check inside its download instead of racing it: the
        // gate holds the check — and the service's in-flight flag — open
        // until the test resumes it, so the second check below provably
        // overlaps the first. Structural overlap, not scheduling luck.
        await client.armDownloadSuspension()
        let service = makeService(client: client, store: store)

        let first = Task.detached { await service.checkForUpdates() }
        // Wait for the first check to reach the gate: the request is recorded
        // immediately before the park point, so from here on the check cannot
        // finish before the test resumes it. (The spin is a one-way latch,
        // not a race — reaching the gate means parked.)
        var spins = 0
        while await client.downloadRequests.isEmpty, spins < 100_000 {
            spins += 1
            await Task.yield()
        }
        let downloadRequests = await client.downloadRequests
        XCTAssertFalse(downloadRequests.isEmpty)

        await service.checkForUpdates() // must be suppressed, not queued
        await client.releaseDownloadSuspension()
        await first.value

        let fetched = await client.fetchedEndpoints
        XCTAssertEqual(fetched.count, 1)
    }

    // MARK: - Configuration

    /// Absent, blank, and non-https endpoint values all keep OTA updates
    /// disabled. The service-level no-op test covers the `nil` path end to
    /// end; this pins the parsing rule itself.
    func testEndpointParseDisablesUpdatesWithoutValidHTTPSEndpoint() {
        XCTAssertNil(ModelUpdateConfiguration.parseEndpoint(nil))
        XCTAssertNil(ModelUpdateConfiguration.parseEndpoint(""))
        XCTAssertNil(ModelUpdateConfiguration.parseEndpoint("   \n "))
        XCTAssertNil(
            ModelUpdateConfiguration.parseEndpoint("http://models.example.com"))
        XCTAssertNil(ModelUpdateConfiguration.parseEndpoint("not a url"))
        XCTAssertEqual(
            ModelUpdateConfiguration.parseEndpoint("https://models.example.com"),
            URL(string: "https://models.example.com"))
        // A leading/trailing-blank https value still counts as configured.
        XCTAssertEqual(
            ModelUpdateConfiguration.parseEndpoint("  https://models.example.com\n"),
            URL(string: "https://models.example.com"))
    }

    // MARK: - Store

    /// The store refuses an unsafe version itself, even without the service's
    /// check in the loop, and writes nothing.
    func testStoreStageRejectsAnUnsafeVersion() throws {
        let store = makeStore()
        let hostile = try ModelUpdateManifest(json: FarmManifestFixture.json(version: "../evil", artifact: artifact))
        XCTAssertThrowsError(try store.stage(artifact: artifact, manifest: hostile)) { error in
            guard case .invalidManifest? = error as? ModelUpdateError else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.baseURL.path))
    }

    /// A loader that finishes loading a model an update has since replaced
    /// changes nothing: the newer model stays pending and the active one stays
    /// active, files and all.
    func testMarkingAModelNoLongerPendingChangesNothing() throws {
        let store = makeStore()
        try store.stage(artifact: artifact, manifest: manifest("trick-v1.2"))
        store.markLoaded(ModelVersion("trick-v1.2"))
        try store.stage(artifact: artifact, manifest: manifest("trick-v1.3"))
        // The loader reads trick-v1.3; an update replaces it with trick-v1.4.
        try store.stage(artifact: artifact, manifest: manifest("trick-v1.4"))

        store.markLoaded(ModelVersion("trick-v1.3"))
        XCTAssertEqual(store.activeModel()?.version, ModelVersion("trick-v1.2"))
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.4"))
        store.discard(ModelVersion("trick-v1.3"))
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.4"))
        XCTAssertEqual(
            files(in: store),
            ["staged-models.json", "trick-v1.2.mlpackage.zip", "trick-v1.2.manifest.json",
             "trick-v1.4.mlpackage.zip", "trick-v1.4.manifest.json"])
    }

    /// Staging the active model's own version keeps its files and leaves
    /// nothing pending.
    func testStagingTheActiveVersionKeepsItsFiles() throws {
        let store = makeStore()
        try store.stage(artifact: artifact, manifest: manifest("trick-v1.3"))
        store.markLoaded(ModelVersion("trick-v1.3"))
        try store.stage(artifact: artifact, manifest: manifest("trick-v1.3"))

        XCTAssertNil(store.pendingModel())
        let active = try XCTUnwrap(store.activeModel())
        XCTAssertEqual(try Data(contentsOf: active.artifactURL), artifact)
    }

    /// An unreadable record must not wedge the store: it reads as nothing
    /// staged, and the next stage rewrites it and clears what the directory
    /// held, files of another schema included.
    func testAnUnreadableRecordOrAnotherSchemasFilesHeal() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.baseURL, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.baseURL.appendingPathComponent("staged-models.json"))
        try Data(#"{"version": "2026.09.10", "fileName": "m.tflite"}"#.utf8)
            .write(to: store.baseURL.appendingPathComponent("active-model.json"))
        try Data("old".utf8).write(to: store.baseURL.appendingPathComponent("m.tflite"))
        XCTAssertNil(store.activeModel())
        XCTAssertNil(store.pendingModel())

        try store.stage(artifact: artifact, manifest: manifest("trick-v1.3"))
        XCTAssertEqual(store.pendingModel()?.version, ModelVersion("trick-v1.3"))
        XCTAssertEqual(
            files(in: store),
            ["staged-models.json", "trick-v1.3.mlpackage.zip", "trick-v1.3.manifest.json"])
    }

    /// A record naming a model whose artifact is gone reads as no model.
    func testARecordWithoutItsArtifactIsNoModel() throws {
        let store = makeStore()
        try store.stage(artifact: artifact, manifest: manifest("trick-v1.3"))
        let pending = try XCTUnwrap(store.pendingModel())
        try FileManager.default.removeItem(at: pending.artifactURL)
        XCTAssertNil(store.pendingModel())
    }

    // MARK: - Client

    /// Model bytes are trust material: the client refuses to fetch or download
    /// over plain http, before any bytes move.
    func testClientRequiresHTTPS() async {
        let client = URLSessionModelUpdateClient()
        do {
            _ = try await client.fetchManifest(
                from: URL(string: "http://farm.example.com/api/models/current")!)
            XCTFail("expected endpointNotHTTPS")
        } catch ModelUpdateError.endpointNotHTTPS {
            // expected
        } catch {
            XCTFail("expected endpointNotHTTPS, got \(error)")
        }
        do {
            _ = try await client.downloadModel(from: URL(string: "http://r2.example.com/m.zip")!)
            XCTFail("expected endpointNotHTTPS")
        } catch ModelUpdateError.endpointNotHTTPS {
            // expected
        } catch {
            XCTFail("expected endpointNotHTTPS, got \(error)")
        }
    }

    /// The farm's statuses: a 200's body is the manifest, its `404 NO_MODEL`
    /// means nothing is published, and any other status is a failure.
    func testClientReadsTheFarmsStatuses() throws {
        let endpoint = URL(string: "https://farm.example.com/api/models/current")!
        let response = { (status: Int) in
            HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        let manifest = FarmManifestFixture.json(version: "trick-v1.3", artifact: artifact)
        XCTAssertEqual(try URLSessionModelUpdateClient.manifestBody(manifest, response: response(200)), manifest)

        let noModel = Data(#"{"error":{"code":"NO_MODEL","message":"no model yet","details":{}}}"#.utf8)
        XCTAssertNil(try URLSessionModelUpdateClient.manifestBody(noModel, response: response(404)))

        let notFound = Data(#"{"error":{"code":"NOT_FOUND","message":"not found","details":{}}}"#.utf8)
        for (body, status) in [(notFound, 404), (Data(), 500), (manifest, 403)] {
            XCTAssertThrowsError(try URLSessionModelUpdateClient.manifestBody(body, response: response(status))) {
                guard case .network? = $0 as? ModelUpdateError else {
                    return XCTFail("expected network for \(status), got \($0)")
                }
            }
        }
    }
}

// MARK: - Mock configuration

private extension MockModelUpdateClient {
    /// Actor-isolated state can't be set with a plain assignment from the test,
    /// so these small setters keep the tests readable.
    func setManifest(_ manifest: Data) {
        self.manifest = manifest
        self.manifestError = nil
    }

    func setManifestError(_ error: Error) {
        self.manifestError = error
    }

    func setDownloadBytes(_ bytes: Data) {
        self.downloadBytes = bytes
        self.downloadError = nil
    }

    /// Arms the one-shot download gate: the next `downloadModel` call parks
    /// instead of completing. Call before starting the first check.
    func armDownloadSuspension() {
        suspendNextDownload = true
    }

    /// Resumes the parked `downloadModel` call, if any, letting the first
    /// check finish. Call after the overlapping work has been issued.
    func releaseDownloadSuspension() {
        suspendedDownload?.resume()
        suspendedDownload = nil
    }
}
