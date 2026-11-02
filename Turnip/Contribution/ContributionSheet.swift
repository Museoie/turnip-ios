import SwiftUI

/// Drives the confirmation sheet: nothing is sent until Confirm, and what the sheet reports at
/// the end is the farm's own read-back of the source — done only when every clip came back with
/// the names it was sent with.
@MainActor
final class ContributionViewModel: ObservableObject {
    enum Phase: Equatable {
        case reviewing
        case sending(ContributionUploader.Step)
        case done(clipCount: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .reviewing
    let plan: ContributionPlan
    let account: FarmAccount

    init(plan: ContributionPlan, account: FarmAccount) {
        self.plan = plan
        self.account = account
    }

    var canConfirm: Bool {
        guard account.isSignedIn, plan.source != nil else { return false }
        switch phase {
        case .reviewing, .failed: return true
        case .sending, .done: return false
        }
    }

    func confirm() async {
        guard let source = plan.source, let client = account.client,
              let session = account.credentials.sessionToken
        else { return }
        phase = .sending(.registering)
        let uploader = ContributionUploader(client: client, credentials: account.credentials)
        do {
            let stored = try await uploader.contribute(source, session: session) { step in
                Task { @MainActor in
                    if case .sending = self.phase { self.phase = .sending(step) }
                }
            }
            phase = source.clipsNotHeld(by: stored).isEmpty
                ? .done(clipCount: source.clips.count)
                : .failed(String(localized: """
                    The farm's copy doesn't match what was sent: trick names are missing or different. \
                    Try again later.
                    """))
        } catch FarmError.unauthenticated {
            account.sessionEnded()
            phase = .failed(FarmError.unauthenticated.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The contribution confirmation sheet (`docs/CONTRIBUTION_DESIGN.md` §3.3): the saved, named
/// clips Settings' Contribute named clips offers, with their names; what is sent and what never
/// is; the disclosure the farm requires; sign-in when there is no session; and Confirm. Cancel
/// sends nothing — the clips are already saved.
struct ContributionSheet: View {
    @StateObject private var model: ContributionViewModel
    @ObservedObject private var account: FarmAccount
    let thumbnail: (ClipListItem) async -> CGImage?
    @Environment(\.dismiss) private var dismiss
    @State private var signInFailure: String?

    init(
        model: @autoclosure @escaping () -> ContributionViewModel,
        thumbnail: @escaping (ClipListItem) async -> CGImage?
    ) {
        let built = model()
        _model = StateObject(wrappedValue: built)
        _account = ObservedObject(wrappedValue: built.account)
        self.thumbnail = thumbnail
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.plan.clips, id: \.item.id) { entry in
                        ContributionClipRow(item: entry.item, status: entry.status, thumbnail: thumbnail)
                    }
                } footer: {
                    qualityNote
                }
                Section("What's sent") {
                    Text(ContributionDisclosure.payload)
                    Text(ContributionDisclosure.linkWindow)
                    Text(ContributionDisclosure.deletionReach)
                    Label {
                        Text(ContributionDisclosure.consent)
                    } icon: {
                        Image(systemName: model.plan.includesSomeoneElse ? "exclamationmark.triangle.fill" : "person")
                            .foregroundStyle(model.plan.includesSomeoneElse ? Color.yellow : Color.secondary)
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
                    Button(isDone ? "Done" : "Not Now") { dismiss() }
                        .disabled(isSending)
                        .accessibilityIdentifier("contribution-dismiss")
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .errorAlert("Couldn't sign in", message: $signInFailure)
        }
        .interactiveDismissDisabled(isSending)
    }

    private var isSending: Bool {
        if case .sending = model.phase { return true }
        return false
    }

    private var isDone: Bool {
        if case .done = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var qualityNote: some View {
        switch model.plan.quality {
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

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .reviewing, .failed:
            VStack(spacing: 8) {
                if case .failed(let message) = model.phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("contribution-failure")
                }
                PrimaryActionBar(
                    model.phase == .reviewing ? "Contribute" : "Try Again",
                    isEnabled: model.canConfirm
                ) {
                    Task { await model.confirm() }
                }
                .accessibilityIdentifier("contribution-confirm")
            }
        case .sending(let step):
            ProgressView { Text(Self.label(for: step)) }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.thinMaterial)
                .accessibilityIdentifier("contribution-progress")
        case .done(let clipCount):
            Label(Self.doneMessage(clipCount: clipCount), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.thinMaterial)
                .accessibilityIdentifier("contribution-done")
        }
    }

    /// Counts what the farm's read-back holds of the clips just sent.
    private static func doneMessage(clipCount: Int) -> String {
        clipCount == 1
            ? String(localized: "The farm has this clip. Thank you.")
            : String(localized: "The farm has these \(clipCount) clips. Thank you.")
    }

    private static func label(for step: ContributionUploader.Step) -> String {
        switch step {
        case .registering: return String(localized: "Registering the video…")
        case .uploadingPose: return String(localized: "Uploading pose keypoints…")
        case .waitingForFarm: return String(localized: "Waiting for the farm to process the pose…")
        case .sendingNames: return String(localized: "Sending trick names…")
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
