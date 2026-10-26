import AuthenticationServices
import SwiftUI

/// Settings' Contribution section (`docs/CONTRIBUTION_DESIGN.md` §5.4): sign in with Apple, sign
/// out, and delete the farm account. Shown only when the build points at a farm.
struct FarmAccountSection: View {
    @ObservedObject var account: FarmAccount
    @State private var isConfirmingDeletion = false
    @State private var failureMessage: String?

    var body: some View {
        Section {
            if account.isSignedIn {
                Label("Signed in with Apple", systemImage: "checkmark.seal")
                    .accessibilityIdentifier("settings-farm-signed-in")
                Button("Sign Out") {
                    Task { await account.signOut() }
                }
                .disabled(account.isWorking)
                .accessibilityIdentifier("settings-farm-sign-out")
                Button("Delete Account", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .disabled(account.isWorking)
                .accessibilityIdentifier("settings-farm-delete-account")
            } else {
                FarmSignInButton(account: account, failureMessage: $failureMessage)
                    .accessibilityIdentifier("settings-farm-sign-in")
            }
        } header: {
            Text("Contribution")
        } footer: {
            Text(ContributionDisclosure.accountFooter)
        }
        .confirmationDialog(
            "Delete your Turnip account?", isPresented: $isConfirmingDeletion, titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task {
                    do {
                        try await account.deleteAccount()
                    } catch {
                        failureMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(ContributionDisclosure.accountDeletion)
        }
        .errorAlert("Couldn't finish", message: $failureMessage)
    }
}

/// The system Sign in with Apple button, wired to the farm account. Shared by Settings and the
/// contribution sheet, the two places a user can sign in.
struct FarmSignInButton: View {
    @ObservedObject var account: FarmAccount
    @Binding var failureMessage: String?

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            account.prepare(request)
        } onCompletion: { result in
            Task {
                do {
                    try await account.complete(result)
                } catch {
                    failureMessage = error.localizedDescription
                }
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 44)
        .disabled(account.isWorking)
    }
}

/// The words the farm requires at contribution consent and again at account deletion
/// (`BACKEND_DESIGN.md` §7.1), kept in one place so the two can't drift apart.
enum ContributionDisclosure {
    static let payload = String(localized: """
        Sends pose keypoints, the clip's start and end, and its trick names. \
        Your video never leaves this iPhone.
        """)
    static let linkWindow = String(localized: """
        Contributions stay linked to your account for 30 days after you last change them, \
        then are kept without any link to it.
        """)
    static let deletionReach = String(localized: """
        Deleting your account removes every contribution this app can still find. The rest \
        can't be traced back to you and stay in the training data.
        """)
    static let consent = String(localized: """
        Contribute only clips of yourself, or of people who agreed.
        """)
    static let accountFooter = String(localized: """
        Signing in lets you contribute named clips to train Turnip's trick detection. \
        Nothing else in the app needs an account.
        """)
    static var accountDeletion: String { "\(linkWindow) \(deletionReach)" }
}
