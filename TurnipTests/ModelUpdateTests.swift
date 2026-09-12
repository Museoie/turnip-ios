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

    // MARK: - Manifest decoding

    /// The manifest must decode from the exact JSON shape turnip-farm will
    /// serve — this test pins the contract the client, store, and server share.
    func testManifestDecodesFromJSON() throws {
        let json = """
        {
          "version": "2026.09.10-1",
          "downloadURL": "https://models.example.com/movenet_thunder_int8.tflite",
          "sha256": "abc123",
          "fileName": "movenet_thunder_int8.tflite"
        }
        """.data(using: .utf8)!
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
        guard let updateError = lastError as? ModelUpdateError,
              case .checksumMismatch = updateError else {
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
        await client.setManifestError(ModelUpdateError.network(underlying: CocoaError(.fileReadNoSuchFile)))
        await service.checkForUpdates() // must not throw

        // The previously staged model is still the active one.
        let activeURL = try XCTUnwrap(store.activeModelURL())
        XCTAssertEqual(try Data(contentsOf: activeURL), bytes)
        XCTAssertEqual(store.activeVersion(), ModelVersion("2026.09.10-1"))
        XCTAssertNotNil(await service.lastError)
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
        XCTAssertNil(await service.lastError)
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
        guard let updateError = lastError as? ModelUpdateError,
              case .invalidManifest = updateError else {
            return XCTFail("expected invalidManifest, got \(String(describing: lastError))")
        }
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
