import Foundation

/// Persists `TurnipSettings` to `UserDefaults`, the standard mechanism for a handful of small
/// preference values in an app this size, rather than a bespoke file format.
///
/// `@MainActor` and `ObservableObject` so `SettingsView` can bind straight to its published
/// properties. Every other consumer (`CameraCaptureViewModel`, the Home/Processing wiring,
/// `ClipListViewModel`) is on the main actor at the point it needs a setting — arming a
/// recording, starting a pipeline run, saving a clip are all user-driven, MainActor entry
/// points — so they read `current` there and pass the plain `TurnipSettings` value down into
/// `Sendable` types instead of holding a reference to this store.
@MainActor
final class TurnipSettingsStore: ObservableObject {
    static let shared = TurnipSettingsStore()

    private enum Key {
        static let analysisMode = "settings.analysisMode"
        static let autoAddToAlbum = "settings.autoAddToAlbum"
        static let albumName = "settings.albumName"
        static let analysisGranularity = "settings.analysisGranularity"
    }

    private let defaults: UserDefaults

    @Published var analysisMode: AnalysisMode {
        didSet { defaults.set(analysisMode.rawValue, forKey: Key.analysisMode) }
    }
    @Published var autoAddToAlbum: Bool {
        didSet { defaults.set(autoAddToAlbum, forKey: Key.autoAddToAlbum) }
    }
    @Published var albumName: String {
        didSet { defaults.set(albumName, forKey: Key.albumName) }
    }
    @Published private(set) var analysisGranularity: Int

    /// `defaults` is injectable so tests exercise a real round trip against an isolated
    /// `UserDefaults` suite rather than the app's shared one.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMode = defaults.string(forKey: Key.analysisMode).flatMap(AnalysisMode.init(rawValue:))
        let storedGranularity = defaults.object(forKey: Key.analysisGranularity) as? Int
        let loaded = TurnipSettings(
            analysisMode: storedMode ?? .realTime,
            autoAddToAlbum: defaults.object(forKey: Key.autoAddToAlbum) as? Bool ?? false,
            albumName: defaults.string(forKey: Key.albumName) ?? TurnipSettings.defaultAlbumName,
            analysisGranularity: storedGranularity ?? TurnipSettings.defaultGranularity)
        analysisMode = loaded.analysisMode
        autoAddToAlbum = loaded.autoAddToAlbum
        albumName = loaded.albumName
        analysisGranularity = loaded.analysisGranularity
    }

    /// The Settings screen's stepper goes through this rather than a plain `@Published` setter,
    /// so an out-of-range value (a bug in a future control, or a raced write) can never reach
    /// storage unclamped.
    func setAnalysisGranularity(_ value: Int) {
        let clamped = TurnipSettings.clampedGranularity(value)
        guard clamped != analysisGranularity else { return }
        analysisGranularity = clamped
        defaults.set(analysisGranularity, forKey: Key.analysisGranularity)
    }

    /// A plain snapshot for a call site that isn't binding to individual published properties —
    /// read once at the point a setting takes effect (Record tap, pipeline start, Photos save)
    /// rather than held onto, so a mid-session change is picked up by the next action instead of
    /// needing every reader to also observe this store.
    var current: TurnipSettings {
        TurnipSettings(
            analysisMode: analysisMode,
            autoAddToAlbum: autoAddToAlbum,
            albumName: albumName,
            analysisGranularity: analysisGranularity)
    }
}
