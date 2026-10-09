import XCTest
@testable import Turnip

/// Pure `TurnipSettings` value-type tests: defaulting and granularity clamping, independent of
/// `UserDefaults`. `TurnipSettingsStoreTests` covers the persistence round trip on top of this.
final class TurnipSettingsTests: XCTestCase {
    func testDefaultInitializerValuesMatchTheAppsRealTimeNoAlbumTenPerSecondDefaults() {
        let settings = TurnipSettings()

        XCTAssertEqual(settings.analysisMode, .realTime)
        XCTAssertFalse(settings.autoAddToAlbum)
        XCTAssertEqual(settings.albumName, TurnipSettings.defaultAlbumName)
        XCTAssertEqual(settings.analysisGranularity, 10)
    }

    func testDefaultGranularityMatchesTheSamplersOwnDefault() {
        // The two must never drift apart: this is what makes "no setting saved yet" behave
        // identically to "the analysis granularity setting doesn't exist."
        XCTAssertEqual(TurnipSettings.defaultGranularity, VideoFrameSampler.targetSamplesPerSecond)
    }

    // MARK: - Granularity clamping (1...30)

    func testGranularityWithinRangePassesThroughUnchanged() {
        XCTAssertEqual(TurnipSettings(analysisGranularity: 1).analysisGranularity, 1)
        XCTAssertEqual(TurnipSettings(analysisGranularity: 30).analysisGranularity, 30)
        XCTAssertEqual(TurnipSettings(analysisGranularity: 17).analysisGranularity, 17)
    }

    func testGranularityBelowOneClampsToOne() {
        XCTAssertEqual(TurnipSettings(analysisGranularity: 0).analysisGranularity, 1)
        XCTAssertEqual(TurnipSettings(analysisGranularity: -5).analysisGranularity, 1)
    }

    func testGranularityAboveThirtyClampsToThirty() {
        XCTAssertEqual(TurnipSettings(analysisGranularity: 31).analysisGranularity, 30)
        XCTAssertEqual(TurnipSettings(analysisGranularity: 1000).analysisGranularity, 30)
    }

    func testClampedGranularityIsThePureFunctionBothEntryPointsShareOut() {
        XCTAssertEqual(TurnipSettings.clampedGranularity(0), 1)
        XCTAssertEqual(TurnipSettings.clampedGranularity(30), 30)
        XCTAssertEqual(TurnipSettings.clampedGranularity(31), 30)
        XCTAssertEqual(TurnipSettings.clampedGranularity(10), 10)
    }

    // MARK: - Album destination

    func testAlbumDestinationIsNilWhenAutoAddIsOff() {
        let settings = TurnipSettings(autoAddToAlbum: false, albumName: "Tricks")
        XCTAssertNil(settings.albumDestination)
    }

    func testAlbumDestinationIsTheTrimmedNameWhenAutoAddIsOn() {
        let settings = TurnipSettings(autoAddToAlbum: true, albumName: "  Tricks  ")
        XCTAssertEqual(settings.albumDestination, "Tricks")
    }

    func testAlbumDestinationIsNilWhenAutoAddIsOnButTheNameIsBlank() {
        let settings = TurnipSettings(autoAddToAlbum: true, albumName: "   ")
        XCTAssertNil(settings.albumDestination)
    }
}
