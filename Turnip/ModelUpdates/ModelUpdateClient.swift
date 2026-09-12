import Foundation

/// The network boundary for OTA model updates, behind a protocol so the whole
/// flow is unit-testable against a mock — the server does not exist yet, and no
/// test may depend on it existing.
protocol ModelUpdateClient: Sendable {
    /// Fetches and decodes the manifest at `endpoint`.
    func fetchManifest(from endpoint: URL) async throws -> ModelUpdateManifest
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

    func fetchManifest(from endpoint: URL) async throws -> ModelUpdateManifest {
        try requireHTTPS(endpoint)
        do {
            let (data, _) = try await session.data(from: endpoint)
            return try JSONDecoder().decode(ModelUpdateManifest.self, from: data)
        } catch {
            throw ModelUpdateError.network(underlying: error)
        }
    }

    func downloadModel(from url: URL) async throws -> URL {
        try requireHTTPS(url)
        do {
            let (temporaryURL, _) = try await session.download(from: url)
            return temporaryURL
        } catch {
            throw ModelUpdateError.network(underlying: error)
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
