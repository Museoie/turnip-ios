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

    init(
        analysisMode: AnalysisMode = .realTime,
        autoAddToAlbum: Bool = false,
        albumName: String = TurnipSettings.defaultAlbumName,
        analysisGranularity: Int = TurnipSettings.defaultGranularity
    ) {
        self.analysisMode = analysisMode
        self.autoAddToAlbum = autoAddToAlbum
        self.albumName = albumName
        self.analysisGranularity = Self.clampedGranularity(analysisGranularity)
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
