import Foundation

/// The network boundary for OTA model updates, behind a protocol so the whole
/// flow is unit-testable against a mock — no test may depend on a farm
/// deployment being reachable.
protocol ModelUpdateClient: Sendable {
    /// Fetches the manifest at `endpoint` and returns its JSON as served, or
    /// `nil` when the farm has promoted no model yet. The service decodes it.
    func fetchManifest(from endpoint: URL) async throws -> Data?
    /// Downloads the model bytes, returning a file URL to them. The caller owns
    /// the returned file.
    func downloadModel(from url: URL) async throws -> URL
}

/// The production client: plain `URLSession`, `https`-only.
struct URLSessionModelUpdateClient: ModelUpdateClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchManifest(from endpoint: URL) async throws -> Data? {
        try requireHTTPS(endpoint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: endpoint)
        } catch {
            throw ModelUpdateError.network(underlying: String(describing: error))
        }
        return try Self.manifestBody(data, response: response)
    }

    func downloadModel(from url: URL) async throws -> URL {
        try requireHTTPS(url)
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(from: url)
        } catch {
            throw ModelUpdateError.network(underlying: String(describing: error))
        }
        do {
            try Self.requireSuccess(response)
        } catch {
            // The body of a failed download is an error document, not a model.
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return temporaryURL
    }

    /// The manifest's JSON from a response to `GET /api/models/current`: the
    /// body of a success, `nil` for the farm's `404 NO_MODEL` (nothing promoted
    /// yet, so nothing to do), and a failure for any other status, a 404 from
    /// some other route included.
    static func manifestBody(_ data: Data, response: URLResponse) throws -> Data? {
        if (response as? HTTPURLResponse)?.statusCode == 404,
           (try? JSONDecoder().decode(FarmErrorBody.self, from: data))?.error.code == "NO_MODEL" {
            return nil
        }
        try requireSuccess(response)
        return data
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ModelUpdateError.network(underlying: "HTTP \(status)")
        }
    }

    /// Model bytes are trust material: refuse to fetch or download over plain
    /// `http` before any bytes move, rather than relying on transport security
    /// policy alone.
    private func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw ModelUpdateError.endpointNotHTTPS
        }
    }
}

/// The farm's error body, `{"error": {"code": "NO_MODEL", ...}}`.
private struct FarmErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
    }

    let error: Detail
}
