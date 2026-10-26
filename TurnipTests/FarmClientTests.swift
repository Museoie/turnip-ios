import CryptoKit
import XCTest
@testable import Turnip

/// Records every request and answers from a script, in order.
private final class ScriptedFarm: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var client: FarmClient {
        FarmClient(baseURL: URL(string: "https://farm.test")!) { request in
            try self.answer(request)
        }
    }

    private func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

/// Every Keychain operation, in memory.
private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for name: String) -> String? { lock.withLock { values[name] } }
    func setValue(_ value: String, for name: String) { lock.withLock { values[name] = value } }
    func removeValue(for name: String) { _ = lock.withLock { values.removeValue(forKey: name) } }
    func names(withPrefix prefix: String) -> [String] { lock.withLock { values.keys.filter { $0.hasPrefix(prefix) } } }
}

final class FarmClientTests: XCTestCase {
    private static let videoID = String(repeating: "ab", count: 32)
    private static let clipID = UUID(uuidString: "8F0E2C4A-1B2D-4E5F-9A0B-1C2D3E4F5A6B")!

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testSignInSendsTheAppleCredentialAndReadsTheSession() async throws {
        let farm = ScriptedFarm([
            .init(status: 200, body: #"{"session_token":"tok","expires_at":"2027-01-01T00:00:00Z"}"#)
        ])
        let grant = try await farm.client.signIn(identityToken: "id", authorizationCode: "code", nonce: "raw")

        XCTAssertEqual(grant.sessionToken, "tok")
        let request = try XCTUnwrap(farm.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://farm.test/api/auth/apple")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try json(request)
        XCTAssertEqual(body["identity_token"] as? String, "id")
        XCTAssertEqual(body["authorization_code"] as? String, "code")
        XCTAssertEqual(body["nonce"] as? String, "raw")
    }

    /// Clip ids go out lowercase and the provenance defaults of a heuristic clip go out
    /// explicitly; the session rides in the header and the source key in the clip.
    func testClipBatchMatchesTheFarmsShape() async throws {
        let farm = ScriptedFarm([.init(status: 200, body: #"{"clips":[]}"#)])
        let clip = ClipSubmission(
            clipID: Self.clipID, sourceID: Self.videoID, sourceKey: "key", startFrame: 12, endFrame: 28,
            autoDetected: true, labels: [ClipName(name: "cork", origin: .vocabulary)])
        _ = try await farm.client.submitClips([clip], session: "tok")

        let request = try XCTUnwrap(farm.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let sent = try XCTUnwrap((try json(request)["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["clip_id"] as? String, "8f0e2c4a-1b2d-4e5f-9a0b-1c2d3e4f5a6b")
        XCTAssertEqual(sent["source_id"] as? String, Self.videoID)
        XCTAssertEqual(sent["source_key"] as? String, "key")
        XCTAssertEqual(sent["start_frame"] as? Int, 12)
        XCTAssertEqual(sent["end_frame"] as? Int, 28)
        XCTAssertEqual(sent["auto_detected"] as? Bool, true)
        XCTAssertEqual(sent["suggested_names"] as? [String], [])
        XCTAssertEqual(sent["suggestions_withheld"] as? Bool, false)
        XCTAssertNil(sent["proposal_model_version"])
        let labels = try XCTUnwrap(sent["labels"] as? [[String: String]])
        XCTAssertEqual(labels, [["name": "cork", "origin": "vocabulary"]])
    }

    func testSourceReadsSendTheKeyAsAHeader() async throws {
        let farm = ScriptedFarm([
            .init(status: 200, body: #"{"source":{"id":"x","frame_count":3,"sha256":null},"clips":[]}"#)
        ])
        _ = try await farm.client.source(id: Self.videoID, key: "key", session: "tok")
        XCTAssertEqual(farm.requests.first?.value(forHTTPHeaderField: "Source-Key"), "key")
        XCTAssertEqual(farm.requests.first?.url?.path, "/api/sources/\(Self.videoID)")
    }

    func testFarmErrorsMapToTheCasesTheAppHandles() async {
        let cases: [(ScriptedFarm.Reply, FarmError)] = [
            (.init(status: 409, body: #"{"error":{"code":"SOURCE_ALREADY_CLAIMED","message":"m","details":{}}}"#),
             .sourceAlreadyClaimed),
            (.init(status: 401, body: #"{"error":{"code":"UNAUTHENTICATED","message":"m","details":{}}}"#),
             .unauthenticated),
            (.init(status: 401, body: ""), .unauthenticated),
            (.init(
                status: 429, body: #"{"error":{"code":"RATE_LIMITED","message":"m"}}"#, headers: ["Retry-After": "7"]),
             .rateLimited(retryAfter: 7)),
            (.init(status: 422, body: #"{"error":{"code":"VALIDATION_ERROR","message":"bad end_frame"}}"#),
             .rejected(code: "VALIDATION_ERROR", message: "bad end_frame")),
            (.init(status: 502, body: "<html>"), .http(status: 502))
        ]
        for (reply, expected) in cases {
            do {
                _ = try await ScriptedFarm([reply]).client.currentTaxonomy()
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? FarmError, expected)
            }
        }
    }

    func testTaxonomyDecodesTheFarmsVocabulary() async throws {
        let farm = ScriptedFarm([.init(status: 200, body: """
            {"taxonomy_version":2,"vocabulary":[{"canonical":"cork","aliases":["cork","corkscrew"]}]}
            """)])
        let vocabulary = try await farm.client.currentTaxonomy()
        XCTAssertEqual(vocabulary.taxonomyVersion, 2)
        XCTAssertEqual(vocabulary.canonicalName(for: "Corkscrew"), "cork")
    }

    // MARK: - Uploader

    private func source() -> SourceContribution {
        SourceContribution(
            videoID: Self.videoID,
            pose: ContributionPose(
                sampleRate: 10, slots: Array(repeating: Array(repeating: 0.5, count: 51), count: 30)),
            clips: [ClipContribution(
                clipID: Self.clipID, window: TrickWindow(startTime: 1, endTime: 2), autoDetected: true,
                names: [ClipName(name: "gainer", origin: .typed)])])
    }

    private func registration(blobPresent: Bool) -> ScriptedFarm.Reply {
        .init(status: 200, body: """
            {"source_id":"\(Self.videoID)","r2_key":"poses/x.tkp1.gz","upload_url":"https://r2.test/put",\
            "upload_expires_at":"2026-10-06T08:00:00Z","blob_present":\(blobPresent)}
            """)
    }

    private let readBack = ScriptedFarm.Reply(status: 200, body: """
        {"source":{"id":"x","frame_count":30,"sha256":"d"},"clips":[{"id":"8f0e2c4a-1b2d-4e5f-9a0b-1c2d3e4f5a6b",\
        "start_frame":10,"end_frame":20,"labels":[{"name":"gainer","origin":"typed"}]}]}
        """)

    /// Register, PUT, poll until ingest lands, send the clips, read back — in that order, with one
    /// key minted and kept for the source.
    func testUploadRunsTheProtocolInOrder() async throws {
        let farm = ScriptedFarm([
            registration(blobPresent: false), .init(status: 200, body: ""),
            registration(blobPresent: false), registration(blobPresent: true),
            .init(status: 200, body: #"{"clips":[]}"#), readBack
        ])
        let credentials = FarmCredentials(store: MemorySecrets())
        var uploader = ContributionUploader(client: farm.client, credentials: credentials)
        uploader.sleep = { _ in }

        let stored = try await uploader.contribute(source(), session: "tok")

        XCTAssertEqual(stored.clips.map(\.labels), [[ClipName(name: "gainer", origin: .typed)]])
        XCTAssertEqual(farm.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "POST /api/sources", "PUT /put", "POST /api/sources", "POST /api/sources",
            "POST /api/clips", "GET /api/sources/\(Self.videoID)"
        ])
        let put = farm.requests[1]
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "application/gzip")
        // MD5, not an `x-amz-checksum-*` header, which the presigned URL doesn't sign.
        XCTAssertEqual(
            put.value(forHTTPHeaderField: "Content-MD5"),
            Data(Insecure.MD5.hash(data: try XCTUnwrap(put.httpBody))).base64EncodedString())
        XCTAssertNil(put.value(forHTTPHeaderField: "x-amz-checksum-sha256"))
        let key = try XCTUnwrap(credentials.sourceKey(for: Self.videoID))
        XCTAssertEqual(key.count, 43)
        XCTAssertEqual(try json(farm.requests[0])["source_key"] as? String, key)
        XCTAssertEqual(try json(farm.requests[0])["frame_count"] as? Int, 30)
        let clip = try XCTUnwrap((try json(farm.requests[4])["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(clip["start_frame"] as? Int, 10)
        XCTAssertEqual(clip["end_frame"] as? Int, 20)
    }

    /// The sheet reports success only when the farm gave back every clip with the names it was sent
    /// with; a clip whose names were dropped, as a farm that ignores label objects drops them, isn't.
    func testReadBackCountsAClipOnlyWithTheNamesItWasSentWith() throws {
        let clipID = Self.clipID.uuidString.lowercased()
        func stored(_ labels: String) throws -> RemoteSource {
            try JSONDecoder().decode(RemoteSource.self, from: Data("""
                {"source":{"id":"x","frame_count":30,"sha256":"d"},"clips":[{"id":"\(clipID)",\
                "start_frame":10,"end_frame":20,"labels":\(labels)}]}
                """.utf8))
        }
        XCTAssertEqual(source().clipsNotHeld(by: try stored("[]")).map(\.clipID), [Self.clipID])
        XCTAssertEqual(source().clipsNotHeld(by: try stored(#"[{"name":" Gainer ","origin":"typed"}]"#)), [])
        XCTAssertEqual(
            source().clipsNotHeld(by: try stored(#"[{"name":"cork","origin":"typed"}]"#)).count, 1)
    }

    func testAPoseTheFarmAlreadyHoldsIsNotUploadedAgain() async throws {
        let farm = ScriptedFarm([registration(blobPresent: true), .init(status: 200, body: #"{"clips":[]}"#), readBack])
        let uploader = ContributionUploader(client: farm.client, credentials: FarmCredentials(store: MemorySecrets()))
        _ = try await uploader.contribute(source(), session: "tok")
        XCTAssertFalse(farm.requests.contains { $0.httpMethod == "PUT" })
    }

    /// A key minted for a video someone else already contributed owns nothing, so it isn't kept.
    func testAClaimedVideoDropsTheKeyJustMinted() async {
        let farm = ScriptedFarm([
            .init(status: 409, body: #"{"error":{"code":"SOURCE_ALREADY_CLAIMED","message":"m"}}"#)
        ])
        let credentials = FarmCredentials(store: MemorySecrets())
        let uploader = ContributionUploader(client: farm.client, credentials: credentials)
        do {
            _ = try await uploader.contribute(source(), session: "tok")
            XCTFail("expected a claim conflict")
        } catch {
            XCTAssertEqual(error as? FarmError, .sourceAlreadyClaimed)
        }
        XCTAssertNil(credentials.sourceKey(for: Self.videoID))
    }

    func testGivesUpWaitingForIngestWithBlobMissing() async {
        let farm = ScriptedFarm([
            registration(blobPresent: false), .init(status: 200, body: ""),
            registration(blobPresent: false), registration(blobPresent: false)
        ])
        var uploader = ContributionUploader(client: farm.client, credentials: FarmCredentials(store: MemorySecrets()))
        uploader.ingestPollDelays = [0, 0]
        uploader.sleep = { _ in }
        do {
            _ = try await uploader.contribute(source(), session: "tok")
            XCTFail("expected the wait to give up")
        } catch {
            XCTAssertEqual(error as? FarmError, .blobMissing)
        }
    }
}
