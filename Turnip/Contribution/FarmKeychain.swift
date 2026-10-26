import Foundation
import Security

/// String secrets by name. The Keychain in the app; a dictionary in tests.
protocol SecretStore: Sendable {
    func value(for name: String) -> String?
    func setValue(_ value: String, for name: String)
    func removeValue(for name: String)
    /// Every stored name that starts with `prefix`.
    func names(withPrefix prefix: String) -> [String]
}

/// The farm's credentials, by what they are rather than by Keychain name
/// (`docs/CONTRIBUTION_DESIGN.md` §5.4): the farm session token, the Apple user the session was
/// signed in as (for `getCredentialState(forUserID:)`), and one source key per contributed
/// `video_id`. The source keys are the only record of what this app contributed — the farm keeps
/// no list of anyone's sources — so they outlive sign-out and go only with account deletion.
struct FarmCredentials: Sendable {
    let store: SecretStore

    private static let sessionName = "session-token"
    private static let appleUserName = "apple-user"
    private static let sourceKeyPrefix = "source-key."

    var sessionToken: String? { store.value(for: Self.sessionName) }
    var appleUserID: String? { store.value(for: Self.appleUserName) }

    func signedIn(sessionToken: String, appleUserID: String) {
        store.setValue(sessionToken, for: Self.sessionName)
        store.setValue(appleUserID, for: Self.appleUserName)
    }

    func signedOut() {
        store.removeValue(for: Self.sessionName)
        store.removeValue(for: Self.appleUserName)
    }

    func sourceKey(for videoID: String) -> String? {
        store.value(for: Self.sourceKeyPrefix + videoID)
    }

    /// The source's key, minted and stored the first time the source is contributed: 32 random
    /// bytes, base64url without padding (the 43 characters the farm expects).
    func sourceKeyMintingIfNeeded(for videoID: String) -> (key: String, isNew: Bool) {
        if let existing = sourceKey(for: videoID) { return (existing, false) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let key = Data(bytes).base64URLEncodedString()
        store.setValue(key, for: Self.sourceKeyPrefix + videoID)
        return (key, true)
    }

    func removeSourceKey(for videoID: String) {
        store.removeValue(for: Self.sourceKeyPrefix + videoID)
    }

    var contributedVideoIDs: [String] {
        store.names(withPrefix: Self.sourceKeyPrefix).map { String($0.dropFirst(Self.sourceKeyPrefix.count)) }
    }
}

/// Generic-password items under one service, readable after first unlock and never migrated to
/// another device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), as the farm's client
/// contract asks for both the session token and the source keys.
struct KeychainSecretStore: SecretStore {
    let service: String

    init(service: String = "com.hoiekim.turnip.farm") {
        self.service = service
    }

    func value(for name: String) -> String? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setValue(_ value: String, for name: String) {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery(name) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = baseQuery(name)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func removeValue(for name: String) {
        SecItemDelete(baseQuery(name) as CFDictionary)
    }

    func names(withPrefix prefix: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }

    private func baseQuery(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
