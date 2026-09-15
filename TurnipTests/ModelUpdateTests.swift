import CryptoKit
import XCTest
@testable import Turnip

/// Mock for `ModelUpdateClient`: feeds the service a canned manifest and canned
/// bytes without touching the network — turnip-farm doesn't exist yet, and unit
/// tests must never depend on it existing.
actor MockModelUpdateClient: ModelUpdateClient {
    var manifest: ModelUpdateManifest?
    var manifestError: Error?
    var downloadBytes: Data?
    var downloadError: Error?

    private(set) var fetchedEndpoints: [URL] = []
    private(set) var downloadRequests: [URL] = []

    func fetchManifest(from endpoint: URL) async throws -> ModelUpdateManifest {
        fetchedEndpoints.append(endpoint)
        if let manifestError = manifestError {
            throw manifestError
        }
        return try XCTUnwrap(manifest, "mock manifest not configured")
    }

    func downloadModel(from url: URL) async throws -> URL {
        downloadRequests.append(url)
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

final class ModelUpdateTests: XCTestCase {

    // MARK: - Helpers

    private func makeManifest(
        version: String,
        bytes: Data,
        fileName: String = "movenet_thunder_int8.tflite"
    ) -> ModelUpdateManifest {
        ModelUpdateManifest(
            version: ModelVersion(version),
            downloadURL: URL(string: "https://models.example.com/\(fileName)")!,
            sha256: sha256Hex(bytes),
            fileName: fileName
        )
    }

    private func makeStore() -> ModelUpdateStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelUpdateTests-\(UUID().uuidString)", isDirectory: true)
        return ModelUpdateStore(baseURL: dir)
    }

    private func makeService(
        client: MockModelUpdateClient,
        store: ModelUpdateStore,
        baseURL: URL? = URL(string: "https://models.example.com")!
    ) -> ModelUpdateService<MockModelUpdateClient> {
        ModelUpdateService(baseURL: baseURL, client: client, store: store)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ModelVersion

    /// Numeric components must order numerically, not lexicographically —
    /// `"2026.09.9"` is older than `"2026.09.10"`, but a naive string compare
    /// says the opposite.
    func testVersionOrdersNumericComponentsNumerically() {
        XCTAssertLessThan(ModelVersion("2026.09.9"), ModelVersion("2026.09.10"))
        XCTAssertGreaterThan(ModelVersion("2026.09.10"), ModelVersion("2026.09.9"))
        XCTAssertLessThan(ModelVersion("1"), ModelVersion("2"))
        XCTAssertFalse(ModelVersion("2026.09.10") < ModelVersion("2026.09.10"))
    }

    func testVersionPrefixIsSmaller() {
        XCTAssertLessThan(ModelVersion("1.2"), ModelVersion("1.2.1"))
    }

    /// The documented build-suffix contract: a same-day hotfix re-release is
    /// newer than the bare version, and a missing suffix counts as build 0.
    /// This pins `parse`'s build branch — the subtlest part of `<`.
    func testVersionBuildSuffixOrdersAfterBareVersion() {
        XCTAssertLessThan(ModelVersion("2026.09.10"), ModelVersion("2026.09.10-1"))
        XCTAssertLessThan(ModelVersion("2026.09.10-1"), ModelVersion("2026.09.10-2"))
        XCTAssertGreaterThan(ModelVersion("2026.09.10-2"), ModelVersion("2026.09.10"))
        XCTAssertFalse(ModelVersion("2026.09.10") < ModelVersion("2026.09.10-0"))
        XCTAssertFalse(ModelVersion("2026.09.10-1") < ModelVersion("2026.09.10"))
    }

    /// `isWellFormed` is the gate the service's manifest validation uses:
    /// only dotted-numeric versions with an optional `-N` build suffix order
    /// predictably under `<`. Anything else would fall back to lexicographic
    /// comparison, so these shapes must be rejected before they can reach
    /// the loader's version floor.
    func testVersionWellFormednessMatchesTheOrderingContract() {
        for wellFormed in ["1", "0", "2026.09.10", "2026.09.10-1", "10.0.0-12"] {
            XCTAssertTrue(
                ModelVersion(wellFormed).isWellFormed,
                "\(wellFormed) should be well-formed")
        }
        for malformed in ["", "v2", "2026-09-10", "1.2.", ".1", "1..2", "1.2-",
                          "1.2-a", "-1", "1.2.3-", "1.2.3-4-5", "1. 2"] {
            XCTAssertFalse(
                ModelVersion(malformed).isWellFormed,
                "\(malformed) should be malformed")
        }
    }

    // MARK: - Manifest decoding

    /// The manifest must decode from the exact JSON shape turnip-farm will
    /// serve — this test pins the contract the client, store, and server share.
    func testManifestDecodesFromJSON() throws {
        let json = Data("""
        {
          "version": "2026.09.10-1",
          "downloadURL": "https://models.example.com/movenet_thunder_int8.tflite",
          "sha256": "abc123",
          "fileName": "movenet_thunder_int8.tflite"
        }
        """.utf8)
        let manifest = try JSONDecoder().decode(ModelUpdateManifest.self, from: json)
        XCTAssertEqual(manifest.version, ModelVersion("2026.09.10-1"))
        XCTAssertEqual(
            manifest.downloadURL.absoluteString,
            "https://models.example.com/movenet_thunder_int8.tflite")
        XCTAssertEqual(manifest.sha256, "abc123")
        XCTAssertEqual(manifest.fileName, "movenet_thunder_int8.tflite")
    }

    // MARK: - Service

    /// A newer manifest downloads, verifies, and becomes the active model —
    /// the file on disk must be byte-identical to what the client delivered.
    func testCheckForUpdatesAppliesNewerModel() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let bytes = Data("fake-model-bytes".utf8)
        await client.setManifest(makeManifest(version: "2026.09.10-1", bytes: bytes))
        await client.setDownloadBytes(bytes)

        let service = makeService(client: client, store: store)
        await service.checkForUpdates()

        let activeURL = try XCTUnwrap(store.activeModelURL())
        XCTAssertEqual(try Data(contentsOf: activeURL), bytes)
        XCTAssertEqual(store.activeVersion(), ModelVersion("2026.09.10-1"))
        let fetched = await client.fetchedEndpoints
        XCTAssertEqual(
            fetched,
            [URL(string: "https://models.example.com/api/models/current")!])
        let downloads = await client.downloadRequests
        XCTAssertEqual(
            downloads, [URL(string: "https://models.example.com/movenet_thunder_int8.tflite")!])
    }

    /// Same or older versions must not re-download — the check is a cheap
    /// manifest fetch, not a model fetch, on every launch.
    func testCheckForUpdatesSkipsSameAndOlderVersions() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let bytes = Data("fake-model-bytes".utf8)
        await client.setManifest(makeManifest(version: "2026.09.10-1", bytes: bytes))
        await client.setDownloadBytes(bytes)
        let service = makeService(client: client, store: store)

        await service.checkForUpdates()
        let downloadsAfterFirst = await client.downloadRequests
        XCTAssertEqual(downloadsAfterFirst.count, 1)

        // Same version again: no second download.
        await service.checkForUpdates()
        let downloadsAfterSecond = await client.downloadRequests
        XCTAssertEqual(downloadsAfterSecond.count, 1)

        // Older version: still no download, and the active model is untouched.
        await client.setManifest(makeManifest(version: "2026.09.09-1", bytes: bytes))
        await service.checkForUpdates()
        let downloadsAfterThird = await client.downloadRequests
        XCTAssertEqual(downloadsAfterThird.count, 1)
        XCTAssertEqual(store.activeVersion(), ModelVersion("2026.09.10-1"))
    }

    /// Corrupt bytes must fail the checksum and leave no active model — this is
    /// the guard the whole "never break the app" contract rests on, so the test
    /// feeds bytes that deliberately don't match the manifest hash.
    func testCheckForUpdatesRejectsChecksumMismatch() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let manifest = makeManifest(version: "2026.09.10-1", bytes: Data("real-bytes".utf8))
        await client.setManifest(manifest)
        await client.setDownloadBytes(Data("tampered-bytes".utf8))

        let service = makeService(client: client, store: store)
        await service.checkForUpdates() // must not throw

        XCTAssertNil(store.activeModelURL())
        XCTAssertNil(store.activeVersion())
        let lastError = await service.lastError
        guard case .checksumMismatch? = lastError else {
            return XCTFail("expected checksumMismatch, got \(String(describing: lastError))")
        }
    }

    /// Any client failure surfaces as a swallowed error, never a throw — and a
    /// failed update must not disturb an already-active model.
    func testCheckForUpdatesFailsSilently() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let bytes = Data("fake-model-bytes".utf8)
        await client.setManifest(makeManifest(version: "2026.09.10-1", bytes: bytes))
        await client.setDownloadBytes(bytes)
        let service = makeService(client: client, store: store)
        await service.checkForUpdates()
        XCTAssertNotNil(store.activeModelURL())

        await client.setManifest(makeManifest(version: "2026.09.11-1", bytes: bytes))
        let underlying = String(describing: CocoaError(.fileReadNoSuchFile))
        await client.setManifestError(ModelUpdateError.network(underlying: underlying))
        await service.checkForUpdates() // must not throw

        // The previously staged model is still the active one.
        let activeURL = try XCTUnwrap(store.activeModelURL())
        XCTAssertEqual(try Data(contentsOf: activeURL), bytes)
        XCTAssertEqual(store.activeVersion(), ModelVersion("2026.09.10-1"))
        let lastError = await service.lastError
        XCTAssertNotNil(lastError)
    }

    /// A cancelled check is a deliberate stop, not a failed update: a
    /// `CancellationError` thrown mid-check must not be recorded on
    /// `lastError` where it would be misreported as an update failure. This
    /// test fails against the old single-catch implementation, which boxed
    /// the cancellation into `.network(underlying:)`.
    func testCheckForUpdatesIgnoresCancellationError() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let bytes = Data("fake-model-bytes".utf8)
        await client.setManifest(makeManifest(version: "2026.09.10-1", bytes: bytes))
        await client.setManifestError(CancellationError())

        let service = makeService(client: client, store: store)
        await service.checkForUpdates() // must not throw

        let lastError = await service.lastError
        XCTAssertNil(lastError)
    }

    /// No configured endpoint means no network at all — the service is inert
    /// until turnip-farm exists.
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
    /// costs a single manifest fetch instead of two downloads racing. Fails
    /// against the old implementation, which ran every call to completion.
    func testOverlappingChecksAreSuppressed() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let bytes = Data("fake-model-bytes".utf8)
        await client.setManifest(makeManifest(version: "2026.09.10-1", bytes: bytes))
        await client.setDownloadBytes(bytes)
        let service = makeService(client: client, store: store)

        let first = Task.detached { await service.checkForUpdates() }
        // Spin until the first check has entered its manifest fetch: the
        // in-flight flag is set before the first await, so from here on the
        // second check is guaranteed to overlap it.
        var spins = 0
        while await client.fetchedEndpoints.isEmpty, spins < 100_000 {
            spins += 1
            await Task.yield()
        }
        let fetchedEndpoints = await client.fetchedEndpoints
        XCTAssertFalse(fetchedEndpoints.isEmpty)

        await service.checkForUpdates() // must be suppressed, not queued
        await first.value

        let fetched = await client.fetchedEndpoints
        XCTAssertEqual(fetched.count, 1)
    }

    /// A manifest whose fileName tries to escape the OTA directory must be
    /// rejected before anything is written.
    func testUnsafeFileNameIsRejected() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let bytes = Data("fake-model-bytes".utf8)
        await client.setManifest(
            makeManifest(version: "2026.09.10-1", bytes: bytes, fileName: "../evil.tflite"))
        await client.setDownloadBytes(bytes)

        let service = makeService(client: client, store: store)
        await service.checkForUpdates()

        XCTAssertNil(store.activeModelURL())
        let lastError = await service.lastError
        guard case .invalidManifest? = lastError else {
            return XCTFail("expected invalidManifest, got \(String(describing: lastError))")
        }
    }

    /// A manifest with a malformed version must be rejected before anything
    /// is downloaded: `ModelVersion`'s `Comparable` falls back to
    /// lexicographic order for non-numeric components, so e.g. `"v2"` would
    /// beat the bundled `"1"` and pin the client to a staged file the
    /// version floor was meant to reject.
    func testMalformedVersionIsRejected() async throws {
        let store = makeStore()
        let client = MockModelUpdateClient()
        let bytes = Data("fake-model-bytes".utf8)
        await client.setManifest(makeManifest(version: "v2", bytes: bytes))
        await client.setDownloadBytes(bytes)

        let service = makeService(client: client, store: store)
        await service.checkForUpdates()

        XCTAssertNil(store.activeModelURL())
        let downloadRequests = await client.downloadRequests
        XCTAssertTrue(downloadRequests.isEmpty)
        let lastError = await service.lastError
        guard case .invalidManifest? = lastError else {
            return XCTFail("expected invalidManifest, got \(String(describing: lastError))")
        }
    }

    // MARK: - Configuration

    /// Absent, blank, and non-https endpoint values all keep OTA updates
    /// disabled — the service must stay inert until a real turnip-farm
    /// deployment exists. The service-level no-op test covers the `nil`
    /// path end to end; this pins the parsing rule itself.
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

    // MARK: - Loader version floor

    /// The staged model shadows the bundled one only when its version is
    /// strictly newer — an older staged file must not pin the app to a worse
    /// model, and a stale staged file must not shadow a newer app build's
    /// bundled model. A staged version with no bytes on disk counts as no
    /// staged model at all.
    func testResolveModelPathPrefersStagedOnlyWhenNewer() {
        let bundled = "/bundle/movenet_thunder_int8.tflite"
        let staged = "/support/ModelUpdates/movenet_thunder_int8.tflite"
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: bundled,
                stagedVersion: ModelVersion("2026.09.10-1"),
                stagedPath: staged),
            staged)
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: bundled,
                stagedVersion: ModelVersion("0"),
                stagedPath: staged),
            bundled)
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: bundled,
                stagedVersion: MoveNetThunderModel.bundledModelVersion,
                stagedPath: staged),
            bundled)
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: bundled, stagedVersion: nil, stagedPath: nil),
            bundled)
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: bundled,
                stagedVersion: ModelVersion("2026.09.10-1"),
                stagedPath: nil),
            bundled)
    }

    /// A missing bundled model doesn't abort resolution before the staged
    /// file is consulted (inline review on #117): with no bundled path, a
    /// newer staged model is still the candidate; with no staged model either,
    /// resolution yields nil and the loader reports `modelNotFound`.
    func testResolveModelPathWithMissingBundledModelConsultsStaged() {
        let staged = "/support/ModelUpdates/movenet_thunder_int8.tflite"
        XCTAssertEqual(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: nil,
                stagedVersion: ModelVersion("2026.09.10-1"),
                stagedPath: staged),
            staged)
        XCTAssertNil(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: nil, stagedVersion: nil, stagedPath: nil))
        // A stale staged version still can't pin a missing bundle to a worse
        // model: the version floor applies even with no bundled path.
        XCTAssertNil(
            MoveNetThunderModel.resolveModelPath(
                bundledPath: nil,
                stagedVersion: ModelVersion("0"),
                stagedPath: staged))
    }

    // MARK: - Store

    /// Staging a model under the store's own sidecar name must throw
    /// `invalidManifest` and stage nothing — otherwise the metadata write
    /// would overwrite the model bytes it just staged.
    func testStoreStageRejectsSidecarFileName() throws {
        let store = makeStore()
        do {
            try store.stage(
                modelData: Data("fake-model-bytes".utf8),
                version: ModelVersion("2026.09.10-1"),
                fileName: "active-model.json")
            XCTFail("expected invalidManifest for the sidecar name")
        } catch ModelUpdateError.invalidManifest {
            // expected
        } catch {
            XCTFail("expected invalidManifest, got \(error)")
        }
        XCTAssertNil(store.activeVersion())
        XCTAssertNil(store.activeModelURL())
    }

    /// The store enforces the fileName allowlist itself: staging directly with
    /// a traversal name must throw `invalidManifest` and stage nothing, even
    /// without the service's manifest validation in the loop. This test fails
    /// against the old implementation, which wrote whatever name it was
    /// handed.
    func testStoreStageRejectsUnsafeFileName() throws {
        let store = makeStore()
        let version = ModelVersion("2026.09.10-1")
        for fileName in ["../evil.tflite", "sub/evil.tflite", "..", ""] {
            do {
                try store.stage(
                    modelData: Data("fake-model-bytes".utf8),
                    version: version, fileName: fileName)
                XCTFail("expected invalidManifest for '\(fileName)'")
            } catch ModelUpdateError.invalidManifest {
                // expected
            } catch {
                XCTFail("expected invalidManifest, got \(error)")
            }
            XCTAssertNil(
                store.activeVersion(), "nothing staged for '\(fileName)'")
        }
    }

    /// A staged record the loader proves wrong-variant must be evictable:
    /// after `clearActive()` the store reports no staged version and no
    /// staged file, so the next update check re-stages from the manifest
    /// (the service short-circuits re-downloads while a record exists).
    func testStoreClearActiveEvictsStagedRecord() throws {
        let store = makeStore()
        try store.stage(
            modelData: Data("fake-model-bytes".utf8),
            version: ModelVersion("2026.09.10-1"),
            fileName: "model.tflite")
        XCTAssertNotNil(store.activeVersion())
        XCTAssertNotNil(store.activeModelURL())

        store.clearActive()

        XCTAssertNil(store.activeVersion())
        XCTAssertNil(store.activeModelURL())
    }

    /// Evicting an empty store is a no-op, not an error — the loader calls it
    /// defensively whenever a staged candidate fails the variant check.
    func testStoreClearActiveOnEmptyStoreIsNoOp() {
        let store = makeStore()
        store.clearActive()
        XCTAssertNil(store.activeVersion())
        XCTAssertNil(store.activeModelURL())
    }

    // MARK: - Client

    /// Model bytes are trust material: the client refuses to fetch or download
    /// over plain http, before any bytes move.
    func testClientRequiresHTTPS() async {
        let client = URLSessionModelUpdateClient()
        do {
            _ = try await client.fetchManifest(
                from: URL(string: "http://models.example.com/api/models/current")!)
            XCTFail("expected endpointNotHTTPS")
        } catch ModelUpdateError.endpointNotHTTPS {
            // expected
        } catch {
            XCTFail("expected endpointNotHTTPS, got \(error)")
        }
        do {
            _ = try await client.downloadModel(from: URL(string: "http://models.example.com/m.tflite")!)
            XCTFail("expected endpointNotHTTPS")
        } catch ModelUpdateError.endpointNotHTTPS {
            // expected
        } catch {
            XCTFail("expected endpointNotHTTPS, got \(error)")
        }
    }
}

// MARK: - Mock configuration

private extension MockModelUpdateClient {
    /// Actor-isolated state can't be set with a plain assignment from the test,
    /// so these small setters keep the tests readable.
    func setManifest(_ manifest: ModelUpdateManifest) {
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
}
