import SwiftUI

/// The contribution confirmation sheet (`docs/CONTRIBUTION_DESIGN.md` §3.3), shown until the
/// account has agreed: the saved, named clips Settings' Contribute named clips offers, with their
/// names; what is sent and what never is; the disclosure the farm requires; sign-in when there is
/// no session; and Confirm, which covers these clips and every later save. Cancel sends nothing
/// and agrees to nothing — the clips are already saved.
struct ContributionSheet: View {
    let plan: ContributionPlan
    @ObservedObject var account: FarmAccount
    let thumbnail: (ClipListItem) async -> CGImage?
    let confirm: (SourceContribution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var signInFailure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(plan.clips, id: \.item.id) { entry in
                        ContributionClipRow(item: entry.item, status: entry.status, thumbnail: thumbnail)
                    }
                } footer: {
                    qualityNote
                }
                Section("What's sent") {
                    Text(ContributionDisclosure.payload)
                    Text(ContributionDisclosure.ongoing)
                        .accessibilityIdentifier("contribution-ongoing")
                    Text(ContributionDisclosure.linkWindow)
                    Text(ContributionDisclosure.deletionReach)
                    Label {
                        Text(ContributionDisclosure.consent)
                    } icon: {
                        Image(systemName: plan.includesSomeoneElse ? "exclamationmark.triangle.fill" : "person")
                            .foregroundStyle(plan.includesSomeoneElse ? Color.yellow : Color.secondary)
                    }
                    .accessibilityIdentifier("contribution-consent")
                }
                .font(.footnote)
                if !account.isSignedIn {
                    Section {
                        FarmSignInButton(account: account, failureMessage: $signInFailure)
                            .accessibilityIdentifier("contribution-sign-in")
                    } footer: {
                        Text("Contributing needs a Turnip account. Nothing else in the app does.")
                    }
                }
            }
            .navigationTitle("Contribute Clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                        .accessibilityIdentifier("contribution-dismiss")
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryActionBar("Agree and Contribute", isEnabled: account.isSignedIn && plan.source != nil) {
                    guard let source = plan.source else { return }
                    confirm(source)
                    dismiss()
                }
                .accessibilityIdentifier("contribution-confirm")
            }
            .errorAlert("Couldn't sign in", message: $signInFailure)
        }
    }

    @ViewBuilder
    private var qualityNote: some View {
        switch plan.quality {
        case .good: EmptyView()
        case .patchy:
            Text("Pose tracking lost the athlete in parts of these clips. They can still help.")
        case .unusable:
            Text("""
                Pose tracking couldn't follow this video well enough to contribute it. \
                A slo-mo re-record usually helps.
                """)
        }
    }
}

private struct ContributionClipRow: View {
    let item: ClipListItem
    let status: ContributionPlan.ClipStatus
    let thumbnail: (ClipListItem) async -> CGImage?
    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1, orientation: .up).resizable().scaledToFill()
                } else {
                    Color(.quaternarySystemFill)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.names.map(\.name).joined(separator: " · "))
                    .font(.body.weight(.semibold))
                Text(item.durationLabel).font(.caption).foregroundStyle(.secondary)
                if !item.isMe {
                    Label("Someone else", systemImage: "person.2").font(.caption).foregroundStyle(.yellow)
                }
                if status == .otherPerson {
                    Text("Another person in this video. Their clips can't be contributed yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(status == .ready ? 1 : 0.5)
        .task { image = await thumbnail(item) }
    }
}
