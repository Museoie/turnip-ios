import Foundation

/// Whether the camera scores pose live while recording (`docs/LIVE_POSE.md`) or always defers
/// to the post-recording Processing pipeline. Every take already falls back to Processing when
/// live inference doesn't cover it end to end (model still loading, thermal backoff, dropped
/// samples); this setting picks the starting point between "try live first" (the shipped
/// default) and "skip straight to Processing."
enum AnalysisMode: String, CaseIterable, Identifiable, Sendable {
    case realTime
    case offline

    var id: Self { self }

    var label: String {
        switch self {
        case .realTime: return "Real-time"
        case .offline: return "Offline"
        }
    }
}

/// Whose tricks become clips: the person the pose model is surest of in each frame, or everyone
/// it finds, each followed across the take and given clips of their own (`docs/MULTI_PERSON.md`).
/// Chosen on the camera before a take and on Processing before an analysis, and remembered for
/// the next one.
enum PersonMode: String, CaseIterable, Identifiable, Sendable {
    case one
    case everyone

    var id: Self { self }

    var label: String {
        switch self {
        case .one: return "One person"
        case .everyone: return "Everyone"
        }
    }
}

/// The app's user-configurable preferences, as a plain value type — what `TurnipSettingsStore`
/// persists and hands to code that reads settings off the main actor. Kept separate from the
/// store so defaulting and clamping are pure and directly testable, the same split
/// `VideoFrameSampler.stride` and `LivePoseFrameGate` already use for their own math.
struct TurnipSettings: Equatable, Sendable {
    static let granularityRange = 1...30
    static let defaultGranularity = VideoFrameSampler.targetSamplesPerSecond
    static let defaultAlbumName = "Turnip"

    var analysisMode: AnalysisMode
    var autoAddToAlbum: Bool
    var albumName: String
    private(set) var analysisGranularity: Int
    /// Whether a detected clip starts in the editor's Follow mode, its crop moving with the
    /// athlete (`AutoFollow`), rather than in Still.
    var followAthlete: Bool
    var personMode: PersonMode

    init(
        analysisMode: AnalysisMode = .realTime,
        autoAddToAlbum: Bool = false,
        albumName: String = TurnipSettings.defaultAlbumName,
        analysisGranularity: Int = TurnipSettings.defaultGranularity,
        followAthlete: Bool = false,
        personMode: PersonMode = .one
    ) {
        self.analysisMode = analysisMode
        self.autoAddToAlbum = autoAddToAlbum
        self.albumName = albumName
        self.analysisGranularity = Self.clampedGranularity(analysisGranularity)
        self.followAthlete = followAthlete
        self.personMode = personMode
    }

    /// Clamps to `granularityRange` so a corrupt or out-of-range stored value, or a future
    /// range change, can never hand the sampler or the live frame gate a zero or unbounded rate.
    static func clampedGranularity(_ value: Int) -> Int {
        min(max(value, granularityRange.lowerBound), granularityRange.upperBound)
    }

    /// The album to save into, or `nil` for the current default behavior (no album — the asset
    /// lands wherever an ordinary Photos creation request lands it). `nil` also when
    /// `autoAddToAlbum` is on but the name is blank, since an empty album title isn't a usable
    /// destination.
    var albumDestination: String? {
        guard autoAddToAlbum else { return nil }
        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
