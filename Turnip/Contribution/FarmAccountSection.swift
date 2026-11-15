import AuthenticationServices
import SwiftUI

/// Settings' Contribution section (`docs/CONTRIBUTION_DESIGN.md` §3.3, §5.4): the Contribute named
/// clips switch, what is still waiting to send, then sign in with Apple, sign out, and the two
/// equally weighted ways to delete the farm account: keeping the de-linked training segments, or
/// deleting them too. Shown only when the build points at a farm. Where contributing isn't offered
/// (`ContributionRegion`), the switch and sign-in are hidden, and an account already signed in can
/// still sign out or be deleted.
struct FarmAccountSection: View {
    @ObservedObject var account: FarmAccount
    @ObservedObject var outbox: ContributionOutbox
    @Binding var contributesClips: Bool
    let isContributingOffered: Bool
    @State private var pendingDeletion: ContributionsOnDeletion?
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
                Button(Self.deletionTitle(.keep), role: .destructive) {
                    pendingDeletion = .keep
                }
                .disabled(account.isWorking)
                .accessibilityIdentifier("settings-farm-delete-account")
                Button(Self.deletionTitle(.delete), role: .destructive) {
                    pendingDeletion = .delete
                }
                .disabled(account.isWorking)
                .accessibilityIdentifier("settings-farm-delete-account-and-contributions")
            } else if isContributingOffered {
                FarmSignInButton(account: account, failureMessage: $failureMessage)
                    .accessibilityIdentifier("settings-farm-sign-in")
            }
        } header: {
            Text("Contribution")
        } footer: {
            if isContributingOffered {
                Text("\(ContributionDisclosure.contributeSwitch) \(ContributionDisclosure.accountFooter)")
            } else {
                Text(ContributionDisclosure.unavailableHere)
                    .accessibilityIdentifier("settings-contribution-unavailable")
            }
        }
        .confirmationDialog(
            "Delete your Turnip account?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { choice in
            Button(Self.deletionTitle(choice), role: .destructive) {
                Task {
                    do {
                        try await outbox.deleteAccount(contributions: choice)
                    } catch {
                        failureMessage = error.localizedDescription
                    }
                }
            }
        } message: { choice in
            Text(ContributionDisclosure.deletionMessage(for: choice))
        }
        .errorAlert("Couldn't finish", message: $failureMessage)
    }

    /// The two deletion choices, worded alike and shown alike so neither is the easier tap.
    static func deletionTitle(_ choice: ContributionsOnDeletion) -> String {
        switch choice {
        case .keep: return String(localized: "Delete My Account")
        case .delete: return String(localized: "Delete My Account and Contributions")
        }
    }

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
        Deleting your account removes that link, the full pose recordings, and every contribution \
        this iPhone can find with its training segments. Short, transformed segments of the rest \
        stay, with no link to your account, unless you also choose to delete your contributions. \
        Someone with a video of the same clip could still match them to it.
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
    /// What each deletion choice keeps, then the disclosure again. Deleting a source by its key
    /// deletes its training segments too, so the choice only decides about contributions this
    /// iPhone can't find (`BACKEND_DESIGN.md` §7.3).
    static let deletionKeepingContributions = String(localized: """
        Deletes your account and every contribution this iPhone can find, with the training \
        segments made from them. Contributions it can't find, such as ones from an earlier install, \
        stay as short, transformed training segments with no link to your account.
        """)
    static let deletionWithContributions = String(localized: """
        Deletes your account and every contribution still linked to it, with their training \
        segments, including ones this iPhone can't find, such as ones from an earlier install.
        """)

    static func deletionMessage(for choice: ContributionsOnDeletion) -> String {
        let summary = choice == .keep ? deletionKeepingContributions : deletionWithContributions
        return "\(summary)\n\n\(accountDeletion)"
    }

    /// The version of the words the sheet shows. An agreement counts only for the version it was
    /// given to (`FarmCredentials.hasConsented`), so bumping this asks every account again on its
    /// next save. Bump it whenever a line the sheet shows changes what the user agrees to.
    /// The farm records the version with the agreement (`POST /api/consent`) and refuses uploads
    /// from an account that hasn't agreed to its current one (`BACKEND_DESIGN.md` §7.3).
    /// Version 1 was the wording before clips of someone else stayed behind and before the
    /// 16-or-older confirmation; versions 1 and 2 said contributions were unlinked 30 days after
    /// their last edit. Version 3 keeps the link until the account is deleted.
    static let version = 3
}
