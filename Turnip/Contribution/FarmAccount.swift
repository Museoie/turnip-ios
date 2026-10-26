import AuthenticationServices
import Foundation

/// The farm account: Sign in with Apple exchanged for a farm session, sign-out, and account
/// deletion (`docs/CONTRIBUTION_DESIGN.md` §5.4, `BACKEND_DESIGN.md` §7.1). Contributing is the
/// app's only signed-in action, so nothing else reads this.
///
/// The session token and the Apple user it belongs to live in the Keychain (`FarmCredentials`);
/// `isSignedIn` mirrors whether a token is held. No Apple scopes are requested: the farm keeps
/// nothing but the per-app `sub`, so asking for a name or an email would only collect them.
@MainActor
final class FarmAccount: ObservableObject {
    static let shared = FarmAccount(
        client: FarmConfiguration.endpoint.map(FarmClient.live),
        credentials: FarmCredentials(store: KeychainSecretStore()))

    @Published private(set) var isSignedIn: Bool
    @Published private(set) var isWorking = false

    let client: FarmClient?
    let credentials: FarmCredentials
    /// The raw nonce of the sign-in attempt in flight; its SHA-256 went on the Apple request.
    private var pendingNonce: String?

    init(client: FarmClient?, credentials: FarmCredentials) {
        self.client = client
        self.credentials = credentials
        self.isSignedIn = client != nil && credentials.sessionToken != nil
    }

    /// Whether this build points at a farm at all. Without one, no farm control is shown.
    var isAvailable: Bool { client != nil }

    /// `SignInWithAppleButton`'s request hook: a fresh nonce per attempt, no scopes.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let nonce = Data(bytes).base64URLEncodedString()
        pendingNonce = nonce
        request.requestedScopes = []
        request.nonce = VideoIdentity.sha256Hex(Data(nonce.utf8))
    }

    /// `SignInWithAppleButton`'s completion: hands the identity token and the single-use
    /// authorization code to the farm right away, and keeps the session it returns. A cancelled
    /// sheet is not an error.
    func complete(_ result: Result<ASAuthorization, Error>) async throws {
        let authorization: ASAuthorization
        switch result {
        case .success(let value): authorization = value
        case .failure(let error):
            guard let code = (error as? ASAuthorizationError)?.code else { throw error }
            if code == .canceled { return }
            throw AppleSignInError(code: code)
        }
        guard let client,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
              let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }),
              let nonce = pendingNonce
        else { throw FarmError.unauthenticated }
        pendingNonce = nil
        isWorking = true
        defer { isWorking = false }
        let grant = try await client.signIn(identityToken: identityToken, authorizationCode: code, nonce: nonce)
        credentials.signedIn(sessionToken: grant.sessionToken, appleUserID: credential.user)
        isSignedIn = true
    }

    /// Ends the farm session and forgets it. The source keys stay: they are how this app can
    /// still manage, or delete, what it contributed after signing back in.
    func signOut() async {
        if let client, let session = credentials.sessionToken {
            try? await client.signOut(session: session)
        }
        sessionEnded()
    }

    /// A `401` anywhere: the session is gone on the farm's side, so drop it here too.
    func sessionEnded() {
        credentials.signedOut()
        isSignedIn = false
    }

    /// Deletes every source this app holds a key for, then the account, then the keys and the
    /// session (`BACKEND_DESIGN.md` §7.3 "Client first"). A source the farm no longer has under
    /// its key answers `404` and only loses its key; any other failure stops before the account
    /// goes, so a retry finds every source still deletable.
    func deleteAccount() async throws {
        guard let client, let session = credentials.sessionToken else { return }
        isWorking = true
        defer { isWorking = false }
        for videoID in credentials.contributedVideoIDs {
            guard let key = credentials.sourceKey(for: videoID) else { continue }
            do {
                try await client.deleteSource(id: videoID, key: key, session: session)
            } catch FarmError.rejected(code: "NOT_FOUND", _) {
                // Already gone, or never registered under this key: nothing left to delete.
            }
            credentials.removeSourceKey(for: videoID)
        }
        do {
            try await client.deleteAccount(session: session)
        } catch FarmError.unauthenticated {
            // The session was already gone; the sources above were what this app could reach.
        }
        sessionEnded()
    }

    /// Launch and foreground check (`BACKEND_DESIGN.md` §7.1): a revoked or vanished Apple
    /// credential ends the farm session too.
    ///
    /// Skipped on the simulator, which is never a trusted device: Apple answers `.revoked` there
    /// for every credential, the one it issued a second earlier included, so the check would sign
    /// out every sign-in as the sheet closes. A real revocation still ends the session there: Apple
    /// tells the farm, the farm drops the session, and the next call's `401` signs the app out.
    func verifyAppleCredential() async {
        #if targetEnvironment(simulator)
        return
        #else
        guard isSignedIn, let userID = credentials.appleUserID else { return }
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
        if state == .revoked || state == .notFound {
            await signOut()
        }
        #endif
    }
}

/// Sign in with Apple's own failure, in words: its error codes print as "error 1000".
struct AppleSignInError: LocalizedError {
    let code: ASAuthorizationError.Code

    var errorDescription: String? {
        switch code {
        case .unknown:
            // What the sheet answers when the device has no Apple Account signed in.
            return String(localized: """
                Sign in with Apple didn't finish. Check that this iPhone is signed in to an Apple Account, \
                then try again.
                """)
        default:
            return String(localized: "Sign in with Apple didn't work. Try again.")
        }
    }
}
