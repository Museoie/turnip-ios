import CryptoKit
import Foundation

/// How a trick name was given (`BACKEND_DESIGN.md` §1.2.18): typed by hand, picked from the
/// vocabulary's suggestions, or kept from the trick model's pre-fill. Provenance for training,
/// never who gave it.
enum LabelOrigin: String, Codable, Hashable, Sendable {
    case typed
    case vocabulary
    case model
}

/// One trick name on a clip, with how it was given. A combo is several on one clip.
struct ClipName: Codable, Hashable, Sendable {
    let name: String
    let origin: LabelOrigin
}

/// A farm call that failed in a way the app reacts to by name, from the farm's error shape
/// (`BACKEND_DESIGN.md` §7.2). Transport failures stay `URLError`.
enum FarmError: Error, Equatable {
    /// The session is gone or was never valid: discard it and sign in again.
    case unauthenticated
    case accountBlocked
    /// The video is already contributed under another source key; it stays local-only.
    case sourceAlreadyClaimed
    /// The uploaded pose hasn't been ingested yet.
    case blobMissing
    case rateLimited(retryAfter: TimeInterval?)
    case appleUnavailable
    case rejected(code: String, message: String)
    case http(status: Int)
}

extension FarmError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthenticated: return String(localized: "Your sign-in expired. Sign in again to contribute.")
        case .accountBlocked: return String(localized: "This account can't contribute.")
        case .sourceAlreadyClaimed: return String(localized: "This video was already contributed from another install.")
        case .blobMissing: return String(localized: "The farm is still processing the pose. Try again in a minute.")
        case .rateLimited: return String(localized: "Too many requests. Try again in a minute.")
        case .appleUnavailable: return String(localized: "Sign in with Apple is unavailable. Try again later.")
        case .rejected(_, let message): return message
        case .http(let status): return String(localized: "The farm answered with an error (\(status)).")
        }
    }
}

/// The turnip-farm REST API (`BACKEND_DESIGN.md` §7.3), as the calls the app makes. Holds no
/// credentials: every call that needs a session or a source key takes it as an argument.
struct FarmClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    let transport: Transport

    /// An ephemeral session: nothing the farm answers is cached or kept in cookies on disk.
    static func live(baseURL: URL) -> FarmClient {
        let session = URLSession(configuration: .ephemeral)
        return FarmClient(baseURL: baseURL) { request in try await session.data(for: request) }
    }

    func signIn(identityToken: String, authorizationCode: String, nonce: String) async throws -> SessionGrant {
        let body = AppleSignInRequest(
            identityToken: identityToken, authorizationCode: authorizationCode, nonce: nonce)
        return try await decode(send("POST", "api/auth/apple", body: body))
    }

    func signOut(session: String) async throws {
        _ = try await send("POST", "api/auth/signout", session: session)
    }

    func deleteAccount(session: String) async throws {
        _ = try await send("DELETE", "api/account", session: session)
    }

    func registerSource(_ registration: SourceRegistrationRequest, session: String) async throws -> SourceRegistration {
        try await decode(send("POST", "api/sources", body: registration, session: session))
    }

    /// PUTs the gzipped TKP1 blob to the presigned staging URL. `Content-MD5` is the
    /// transport-integrity layer: R2 refuses bytes that don't match it. Of the two checksum headers
    /// the farm allows, it is the one that needs no signing: the URL signs only `host`, and an
    /// S3-compatible store may refuse an `x-amz-*` header its signature doesn't cover.
    func uploadPose(_ blob: Data, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = blob
        request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        request.setValue(Data(Insecure.MD5.hash(data: blob)).base64EncodedString(), forHTTPHeaderField: "Content-MD5")
        let (_, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw FarmError.http(status: status) }
    }

    func submitClips(_ clips: [ClipSubmission], session: String) async throws -> [SubmittedClip] {
        let response: ClipsResponse = try await decode(
            send("POST", "api/clips", body: ClipsRequest(clips: clips), session: session))
        return response.clips
    }

    func source(id: String, key: String, session: String) async throws -> RemoteSource {
        try await decode(send("GET", "api/sources/\(id)", session: session, sourceKey: key))
    }

    func deleteSource(id: String, key: String, session: String) async throws {
        _ = try await send("DELETE", "api/sources/\(id)", session: session, sourceKey: key)
    }

    /// The public vocabulary: no session goes with it, so the fetch is tied to no account.
    func currentTaxonomy() async throws -> TrickVocabulary {
        try await decode(send("GET", "api/taxonomy/current"))
    }

    private func send(
        _ method: String, _ path: String, body: (any Encodable)? = nil,
        session: String? = nil, sourceKey: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let session { request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") }
        if let sourceKey { request.setValue(sourceKey, forHTTPHeaderField: "Source-Key") }
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw FarmError.http(status: 0) }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http, body: data) }
        return data
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        try JSONDecoder().decode(Value.self, from: data)
    }

    /// The farm's `{"error": {"code", "message"}}` shape mapped to the cases the app handles by
    /// name; anything else keeps its code and message.
    static func error(status response: HTTPURLResponse, body: Data) -> FarmError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        switch envelope?.error.code {
        case "UNAUTHENTICATED": return .unauthenticated
        case "ACCOUNT_BLOCKED": return .accountBlocked
        case "SOURCE_ALREADY_CLAIMED": return .sourceAlreadyClaimed
        case "BLOB_MISSING": return .blobMissing
        case "APPLE_UNAVAILABLE": return .appleUnavailable
        case "RATE_LIMITED":
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        case let code?: return .rejected(code: code, message: envelope?.error.message ?? code)
        case nil: return response.statusCode == 401 ? .unauthenticated : .http(status: response.statusCode)
        }
    }
}

private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String?
    }
    let error: Body
}

private struct AppleSignInRequest: Encodable {
    let identityToken: String
    let authorizationCode: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case nonce
    }
}

struct SessionGrant: Decodable, Equatable {
    let sessionToken: String

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
    }
}

struct SourceRegistrationRequest: Encodable, Equatable {
    let videoID: String
    let sourceKey: String
    /// Canonical 10 Hz frames (`POSE_FORMAT.md` §6), the space clip windows are validated in.
    let frameCount: Int
    /// The as-sent analysis rate, which the blob's header also carries.
    let sampleRate: Double
    let keypointFormat = "tkp1"

    enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case sourceKey = "source_key"
        case frameCount = "frame_count"
        case sampleRate = "sample_rate"
        case keypointFormat = "keypoint_format"
    }
}

struct SourceRegistration: Decodable, Equatable {
    let sourceID: String
    let uploadURL: URL
    /// The canonical blob is already stored: skip the PUT.
    let blobPresent: Bool

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case uploadURL = "upload_url"
        case blobPresent = "blob_present"
    }
}

/// One clip in a `POST /api/clips` batch. A heuristic or hand-made clip has no proposing model,
/// so its provenance is the farm's defaults: no model version, no suggested names, not withheld.
struct ClipSubmission: Encodable, Equatable, Sendable {
    let clipID: UUID
    let sourceID: String
    let sourceKey: String
    let startFrame: Int
    let endFrame: Int
    let autoDetected: Bool
    var suggestedNames: [String] = []
    var suggestionsWithheld = false
    let labels: [ClipName]

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case sourceID = "source_id"
        case sourceKey = "source_key"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case autoDetected = "auto_detected"
        case suggestedNames = "suggested_names"
        case suggestionsWithheld = "suggestions_withheld"
        case labels
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The farm reads clip ids as lowercase UUIDs; Foundation prints them uppercase.
        try container.encode(clipID.uuidString.lowercased(), forKey: .clipID)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(sourceKey, forKey: .sourceKey)
        try container.encode(startFrame, forKey: .startFrame)
        try container.encode(endFrame, forKey: .endFrame)
        try container.encode(autoDetected, forKey: .autoDetected)
        try container.encode(suggestedNames, forKey: .suggestedNames)
        try container.encode(suggestionsWithheld, forKey: .suggestionsWithheld)
        try container.encode(labels, forKey: .labels)
    }
}

private struct ClipsRequest: Encodable {
    let clips: [ClipSubmission]
}

private struct ClipsResponse: Decodable {
    let clips: [SubmittedClip]
}

struct SubmittedClip: Decodable, Equatable {
    let clipID: String
    let labels: [ClipName]

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case labels
    }
}

/// `GET /api/sources/:id`: what the farm holds for a source this app has the key to.
struct RemoteSource: Decodable, Equatable {
    let source: RemoteSourceRecord
    let clips: [RemoteClip]
}

struct RemoteSourceRecord: Decodable, Equatable {
    let id: String
    let frameCount: Int
    /// The ingested blob's digest; `nil` until the farm has processed the upload.
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case id
        case frameCount = "frame_count"
        case sha256
    }
}

struct RemoteClip: Decodable, Equatable {
    let id: String
    let startFrame: Int
    let endFrame: Int
    let labels: [ClipName]

    enum CodingKeys: String, CodingKey {
        case id
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case labels
    }
}
