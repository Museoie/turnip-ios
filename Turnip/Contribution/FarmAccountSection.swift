import AuthenticationServices
import SwiftUI

/// Settings' Contribution section (`docs/CONTRIBUTION_DESIGN.md` §3.3, §5.4): the Contribute named
/// clips switch, what is still waiting to send, then sign in with Apple, sign out, and deleting the
/// farm account with every contribution. Shown only when the build points at a farm. Where
/// contributing isn't offered (`ContributionRegion`), the switch and sign-in are hidden, and an
/// account already signed in can still sign out or be deleted.
struct FarmAccountSection: View {
    @ObservedObject var account: FarmAccount
    @ObservedObject var outbox: ContributionOutbox
    @Binding var contributesClips: Bool
    let availability: ContributionRegion.Availability
    @State private var isConfirmingDeletion = false
    @State private var failureMessage: String?

    var body: some View {
        Section {
            if isContributingOffered {
                Toggle("Contribute named clips", isOn: $contributesClips)
                    .accessibilityIdentifier("settings-contribute-clips")
            }
            if outbox.waitingClipCount > 0 {
                Label(waitingMessage, systemImage: "arrow.up.circle")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(waitingMessage)
                    .accessibilityIdentifier("settings-contribution-waiting")
            }
            if account.isSignedIn {
                Label("Signed in with Apple", systemImage: "checkmark.seal")
                    .accessibilityIdentifier("settings-farm-signed-in")
                Button("Sign Out") {
                    Task { await account.signOut() }
                }
                .disabled(account.isWorking)
                .accessibilityIdentifier("settings-farm-sign-out")
                Button(Self.deletionTitle, role: .destructive) {
                    isConfirmingDeletion = true
                }
                .disabled(account.isWorking)
                .accessibilityIdentifier("settings-farm-delete-account")
            } else if isContributingOffered {
                FarmSignInButton(account: account, failureMessage: $failureMessage)
                    .accessibilityIdentifier("settings-farm-sign-in")
            }
        } header: {
            Text("Contribution")
        } footer: {
            if isContributingOffered {
                Text("""
                    \(ContributionDisclosure.contributeSwitch) \(ContributionDisclosure.newNames) \
                    \(ContributionDisclosure.accountFooter)
                    """)
            } else {
                Text(ContributionDisclosure.unavailable(availability))
                    .accessibilityIdentifier("settings-contribution-unavailable")
            }
        }
        .confirmationDialog(
            "Delete your Turnip account?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(Self.deletionTitle, role: .destructive) {
                Task {
                    do {
                        try await outbox.deleteAccount()
                    } catch {
                        failureMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(ContributionDisclosure.deletionMessage)
        }
        .errorAlert("Couldn't finish", message: $failureMessage)
    }

    /// The one way to delete the account, which deletes every contribution with it.
    static let deletionTitle = String(localized: "Delete My Account")

    private var isContributingOffered: Bool { availability == .available }

    /// Background uploads say nothing on their own, so this is where a queue stuck behind an
    /// expired session gets noticed.
    private var waitingMessage: String {
        Self.waitingMessage(
            count: outbox.waitingClipCount, isSignedIn: account.isSignedIn,
            hasConsented: account.credentials.hasConsented)
    }

    /// What is waiting, and what it waits for: a sign-in, or an agreement the farm asked for again
    /// (`CONSENT_REQUIRED`), which the next save's contribution sheet asks for.
    static func waitingMessage(count: Int, isSignedIn: Bool, hasConsented: Bool) -> String {
        let waiting = count == 1
            ? String(localized: "1 clip waiting to send.")
            : String(localized: "\(count) clips waiting to send.")
        if !isSignedIn { return "\(waiting) \(String(localized: "Sign in to finish."))" }
        if !hasConsented { return "\(waiting) \(ContributionDisclosure.agreeToFinish)" }
        return waiting
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
        Contributions stay linked to your account until you delete it, or until it goes 24 months \
        without use.
        """)
    static let deletionReach = String(localized: """
        Deleting your account deletes all your contributions. Models already trained on them stay \
        as they are. Backups of the farm keep deleted data for up to 30 days.
        """)
    /// Labels come only from the vocabulary (`BACKEND_DESIGN.md` §1.2.25).
    static let newNames = String(localized: """
        Only trick names in Turnip's shared vocabulary go with a clip. A new name is sent on its \
        own, without the clip, as a suggestion to add to the vocabulary.
        """)
    static let consent = String(localized: """
        Only clips marked as you are contributed. Clips marked as someone else stay on this iPhone.
        """)
    static let ongoing = String(localized: """
        You're only asked this once. After you agree, the named clips of you in each video you save \
        are sent in the background without asking again. Turn off Contribute named clips in \
        Settings to stop.
        """)
    static let unavailableHere = String(localized: """
        Contributing clips isn't available in your country or region.
        """)
    static let needsAppStoreAccount = String(localized: """
        Contributing clips needs an App Store account signed in on this iPhone.
        """)

    /// Why contributing isn't offered, for Settings' footer.
    static func unavailable(_ availability: ContributionRegion.Availability) -> String {
        availability == .needsAppStoreAccount ? needsAppStoreAccount : unavailableHere
    }
    static let agreeToFinish = String(localized: """
        Your next save asks you to agree to the contribution terms, then they send.
        """)
    static let ageConfirmation = String(localized: "I'm 16 or older")
    static let ageRequirement = String(localized: """
        You need to be 16 or older to contribute clips.
        """)
    static let contributeSwitch = String(localized: """
        With Contribute named clips on, your first save asks before anything is sent. After you \
        agree, each save sends its named clips in the background, and an interrupted upload picks \
        up again by itself. Turning this off cancels what's still waiting.
        """)
    static let accountFooter = String(localized: """
        Signing in lets you contribute named clips to train Turnip's trick detection. \
        Nothing else in the app needs an account.
        """)
    static var accountDeletion: String { "\(linkWindow) \(deletionReach)" }
    /// What deletion reaches: every contribution, including ones this iPhone holds no key for,
    /// which the farm deletes by the account they are linked to (`BACKEND_DESIGN.md` §7.3).
    static let deletionSummary = String(localized: """
        Deletes your account and all your contributions, including ones this iPhone can't find, \
        such as ones from an earlier install.
        """)
    /// The confirmation: what deletion reaches, then the disclosure again.
    static var deletionMessage: String { "\(deletionSummary)\n\n\(accountDeletion)" }

    /// The version of the words the sheet shows. An agreement counts only for the version it was
    /// given to (`FarmCredentials.hasConsented`), so bumping this asks every account again on its
    /// next save. Bump it whenever a line the sheet shows changes what the user agrees to.
    /// The farm records the version with the agreement (`POST /api/consent`) and refuses uploads
    /// from an account that hasn't agreed to its current one (`BACKEND_DESIGN.md` §7.3).
    /// Version 1 was the wording before clips of someone else stayed behind and before the
    /// 16-or-older confirmation; versions 1 and 2 said contributions were unlinked 30 days after
    /// their last edit. Version 3 keeps the link until the account is deleted. Its deletion words
    /// changed before any release, from keeping short training segments to deleting everything,
    /// so the version stayed 3: no one had agreed to the earlier version-3 words.
    static let version = 3
}
