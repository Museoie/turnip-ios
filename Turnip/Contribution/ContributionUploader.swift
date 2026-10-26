import Foundation

/// One clip as contribution sends it: its id (the same UUID Clip List minted for its tile), its
/// window in source seconds, whether that window is still the detector's, and its names.
struct ClipContribution: Equatable, Sendable {
    let clipID: UUID
    let window: TrickWindow
    let autoDetected: Bool
    let names: [ClipName]
}

/// Everything contribution sends for one source video: its `video_id`, its pose, and the clips
/// of it the user confirmed.
struct SourceContribution: Equatable, Sendable {
    let videoID: String
    let pose: ContributionPose
    let clips: [ClipContribution]
}

extension SourceContribution {
    /// The clips the farm's read-back doesn't hold as sent: missing, or with other names than
    /// these. Names compare the way the farm dedupes them, ignoring case and spacing.
    func clipsNotHeld(by stored: RemoteSource) -> [ClipContribution] {
        func names(_ list: [ClipName]) -> Set<String> { Set(list.map { TrickVocabulary.normalized($0.name) }) }
        let held = Dictionary(stored.clips.map { ($0.id, names($0.labels)) }, uniquingKeysWith: { first, _ in first })
        return clips.filter { held[$0.clipID.uuidString.lowercased()] != names($0.names) }
    }
}

/// The pose couldn't be compressed for upload; nothing was sent.
struct PoseEncodingError: LocalizedError {
    var errorDescription: String? { String(localized: "Couldn't prepare the pose for upload.") }
}

/// Runs the farm's upload protocol for one source (`docs/CONTRIBUTION_DESIGN.md` §5.1): register
/// the source with its key, PUT the pose blob unless the farm already holds it, wait for the
/// farm's ingest to land it, send the clips with their names, then read the source back — what
/// it returns is what the farm now holds, not what the app hoped it would.
///
/// Every step is an upsert keyed by ids the app owns, so running it again after a failure at any
/// step is safe; a repeated PUT overwrites the same staged bytes.
struct ContributionUploader: Sendable {
    enum Step: Equatable, Sendable {
        case registering
        case uploadingPose
        case waitingForFarm
        case sendingNames
    }

    let client: FarmClient
    let credentials: FarmCredentials
    /// How long to wait before each re-registration that asks whether the uploaded pose has been
    /// ingested yet. The farm sweeps its staging area every 30 seconds, so this covers a few
    /// sweeps before giving up with `FarmError.blobMissing`, which a retry picks up from.
    var ingestPollDelays: [TimeInterval] = [3, 5, 5, 10, 10, 15, 15, 20, 20, 30]
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func contribute(
        _ source: SourceContribution, session: String, progress: @Sendable (Step) -> Void = { _ in }
    ) async throws -> RemoteSource {
        let (key, isNewKey) = credentials.sourceKeyMintingIfNeeded(for: source.videoID)
        let request = SourceRegistrationRequest(
            videoID: source.videoID, sourceKey: key,
            frameCount: source.pose.canonicalFrameCount, sampleRate: Double(source.pose.sampleRate))
        progress(.registering)
        var registration: SourceRegistration
        do {
            registration = try await client.registerSource(request, session: session)
        } catch FarmError.sourceAlreadyClaimed {
            // A key minted just now owns nothing; keeping it would claim a contribution there isn't.
            if isNewKey { credentials.removeSourceKey(for: source.videoID) }
            throw FarmError.sourceAlreadyClaimed
        }
        if !registration.blobPresent {
            guard let blob = source.pose.gzippedTKP1 else { throw PoseEncodingError() }
            progress(.uploadingPose)
            try await client.uploadPose(blob, to: registration.uploadURL)
            progress(.waitingForFarm)
            for delay in ingestPollDelays where !registration.blobPresent {
                try await sleep(delay)
                registration = try await client.registerSource(request, session: session)
            }
            guard registration.blobPresent else { throw FarmError.blobMissing }
        }
        progress(.sendingNames)
        let submissions = source.clips.map { clip in
            let frames = source.pose.canonicalFrames(of: clip.window)
            return ClipSubmission(
                clipID: clip.clipID, sourceID: source.videoID, sourceKey: key,
                startFrame: frames.start, endFrame: frames.end,
                autoDetected: clip.autoDetected, labels: clip.names)
        }
        _ = try await client.submitClips(submissions, session: session)
        return try await client.source(id: source.videoID, key: key, session: session)
    }
}
