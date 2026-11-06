import Foundation
@testable import Turnip

/// Records every request and answers from a script, in order. With the script run out it fails
/// as an unreachable host does.
final class ScriptedFarm: @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    /// Each request as "METHOD /path".
    var calls: [String] { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }

    func script(_ replies: [Reply]) {
        lock.withLock { self.replies += replies }
    }

    var client: FarmClient {
        FarmClient(baseURL: URL(string: "https://farm.test")!) { request in
            try self.answer(request)
        }
    }

    private func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

/// Every Keychain operation, in memory.
final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for name: String) -> String? { lock.withLock { values[name] } }
    func setValue(_ value: String, for name: String) { lock.withLock { values[name] = value } }
    func removeValue(for name: String) { _ = lock.withLock { values.removeValue(forKey: name) } }
    func names(withPrefix prefix: String) -> [String] { lock.withLock { values.keys.filter { $0.hasPrefix(prefix) } } }
}
