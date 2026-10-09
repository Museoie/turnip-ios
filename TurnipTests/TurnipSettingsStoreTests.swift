import XCTest
@testable import Turnip

/// `TurnipSettingsStore`'s persistence round trip, each test against its own isolated
/// `UserDefaults` suite so tests never share state with each other or with the app's real
/// `.standard` defaults.
final class TurnipSettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.hoiekim.turnip.tests.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor
    func testAFreshSuiteLoadsAllFourDefaults() {
        let store = TurnipSettingsStore(defaults: defaults)

        XCTAssertEqual(store.analysisMode, .realTime)
        XCTAssertFalse(store.autoAddToAlbum)
        XCTAssertEqual(store.albumName, TurnipSettings.defaultAlbumName)
        XCTAssertEqual(store.analysisGranularity, 10)
    }

    @MainActor
    func testEachPropertyRoundTripsThroughANewStoreOverTheSameSuite() {
        let first = TurnipSettingsStore(defaults: defaults)
        first.analysisMode = .offline
        first.autoAddToAlbum = true
        first.albumName = "Tricking Sessions"
        first.setAnalysisGranularity(24)

        let second = TurnipSettingsStore(defaults: defaults)

        XCTAssertEqual(second.analysisMode, .offline)
        XCTAssertTrue(second.autoAddToAlbum)
        XCTAssertEqual(second.albumName, "Tricking Sessions")
        XCTAssertEqual(second.analysisGranularity, 24)
    }

    @MainActor
    func testSetAnalysisGranularityClampsBeforePersisting() {
        let store = TurnipSettingsStore(defaults: defaults)

        store.setAnalysisGranularity(99)
        XCTAssertEqual(store.analysisGranularity, 30)
        XCTAssertEqual(defaults.integer(forKey: "settings.analysisGranularity"), 30)

        store.setAnalysisGranularity(-3)
        XCTAssertEqual(store.analysisGranularity, 1)
        XCTAssertEqual(defaults.integer(forKey: "settings.analysisGranularity"), 1)
    }

    /// A store reads an out-of-range value already sitting in defaults defensively too, not
    /// only values it wrote itself — covers a value from a future looser range, or a corrupt
    /// write, surviving into a build that enforces 1...30.
    @MainActor
    func testAnOutOfRangeStoredGranularityIsClampedOnLoad() {
        defaults.set(500, forKey: "settings.analysisGranularity")

        let store = TurnipSettingsStore(defaults: defaults)

        XCTAssertEqual(store.analysisGranularity, 30)
    }

    @MainActor
    func testCurrentSnapshotsTheStoresPublishedProperties() {
        let store = TurnipSettingsStore(defaults: defaults)
        store.analysisMode = .offline
        store.autoAddToAlbum = true
        store.albumName = "Clips"
        store.setAnalysisGranularity(5)

        let snapshot = store.current

        XCTAssertEqual(snapshot, TurnipSettings(
            analysisMode: .offline, autoAddToAlbum: true, albumName: "Clips", analysisGranularity: 5))
    }
}
