import AVFoundation
import Photos
import XCTest
@testable import Turnip

/// Drives the selection state machine end to end against a scripted `PHImageManager`:
/// `init(library:resolver:)` takes the resolver and the resolver takes the image manager, so a tile
/// tap can be followed all the way to `path` without a real photo library. `init` only reads the
/// authorization status, and nothing here calls `reload()`, so no prompt is ever raised.
@MainActor
final class VideoLibrarySelectionTests: XCTestCase {
    func testASuccessfulSelectionPushesTheResolvedVideoOntoThePath() async {
        let url = URL(filePath: "/tmp/turnip-selection-success.mov")
        let manager = ScriptedImageManager(.asset(AVURLAsset(url: url)))
        let model = VideoLibraryViewModel(resolver: PhotoVideoResolver(imageManager: manager))
        let asset = StubAsset("asset-1", duration: 12.5)

        model.select(asset)
        XCTAssertTrue(model.isResolving(asset), "the tapped tile shows as resolving straight away")
        await wait(until: { model.path.count == 1 }, "the resolved video should reach the path")

        XCTAssertEqual(model.path.first?.assetIdentifier, "asset-1")
        XCTAssertEqual(model.path.first?.asset.url, url)
        XCTAssertEqual(model.path.first?.duration, 12.5)
        XCTAssertNil(model.path.first?.detectedClips, "a tapped tile has not been analyzed")
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.resolution)
        XCTAssertFalse(model.isResolving(asset), "the spinner clears once the video is pushed")
    }

    /// A take the camera analyzed while recording carries its clips onto the path, which is
    /// what makes Home land it on the clip list instead of Processing.
    func testClipsDetectedLiveTravelWithThePushedVideo() async {
        let url = URL(filePath: "/tmp/turnip-selection-live.mov")
        let manager = ScriptedImageManager(.asset(AVURLAsset(url: url)))
        let model = VideoLibraryViewModel(resolver: PhotoVideoResolver(imageManager: manager))
        let clips = [ProcessedClip(
            window: TrickWindow(startTime: 1, endTime: 3),
            cropRect: NormalizedRect(minX: 0.1, maxX: 0.9, minY: 0, maxY: 1))]

        let frames = PoseFixture.frames(hipXPositions: [0.4, 0.5, 0.6])
        let detection = DetectedClips(clips: clips, poseFrames: frames)

        model.select(StubAsset("take-1", duration: 4), detectedClips: detection)
        await wait(until: { model.path.count == 1 }, "the resolved take should reach the path")

        XCTAssertEqual(model.path.first?.detectedClips, detection)
        // The frames ride along: the editor fits crops from them.
        XCTAssertEqual(model.path.first?.detectedClips?.poseFrames.count, 3)
    }

    /// Tiles are disabled while a resolution is in flight, but the state machine must not lean on
    /// the view for that: a second tap is dropped, and the first selection keeps the spinner.
    func testASecondTapWhileAResolutionIsInFlightIsDropped() async {
        let manager = ScriptedImageManager(.silent)
        let model = VideoLibraryViewModel(resolver: PhotoVideoResolver(imageManager: manager))
        let tapped = StubAsset("asset-1")
        let other = StubAsset("asset-2")

        model.select(tapped)
        model.select(other)

        XCTAssertEqual(model.resolution?.assetIdentifier, "asset-1")
        XCTAssertTrue(model.isResolving(tapped))
        XCTAssertFalse(model.isResolving(other), "only the tile being resolved shows a spinner")
        XCTAssertNil(model.downloadProgress(for: other))

        model.cancelSelection()
        await wait(until: { model.resolution == nil }, "cancelling should end the resolution")
        XCTAssertTrue(model.path.isEmpty, "a dropped tap must not push anything")
    }

    /// Backing out is not a failure. Cancelling has to leave the spinner *and* the error banner
    /// clear, or the user is shown an error for something they did deliberately.
    func testCancellingASelectionReportsNoError() async {
        let manager = ScriptedImageManager(.silent)
        let model = VideoLibraryViewModel(resolver: PhotoVideoResolver(imageManager: manager))

        model.select(StubAsset("asset-1"))
        await wait(until: { manager.requestCount == 1 }, "the PhotoKit request should start")
        model.cancelSelection()
        await wait(until: { model.resolution == nil }, "cancelling should end the resolution")

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.path.isEmpty)
    }

    /// A failure surfaces the typed error's own copy rather than PhotoKit's. The distinction is the
    /// whole point of `VideoResolutionError`: the underlying error says "the operation couldn't be
    /// completed", which tells the user nothing about their connection.
    func testAFailedResolutionSurfacesTheTypedErrorsMessage() async {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let manager = ScriptedImageManager(.failure(info: [PHImageErrorKey: underlying]))
        let model = VideoLibraryViewModel(resolver: PhotoVideoResolver(imageManager: manager))

        model.select(StubAsset("asset-1"))
        await wait(until: { model.errorMessage != nil }, "a failed resolution should report")

        XCTAssertEqual(
            model.errorMessage,
            VideoResolutionError.iCloudDownloadFailed(underlying: underlying).errorDescription)
        XCTAssertNil(model.resolution)
        XCTAssertTrue(model.path.isEmpty)
    }

    /// Processing's swipe-to-browse replaces the top of `path` rather than pushing a new entry,
    /// so the back chevron reaches Home in one step regardless of how many videos were browsed.
    func testBrowsingToANeighborReplacesTheTopOfThePathInsteadOfPushing() async {
        let manager = ScriptedImageManager(.asset(AVURLAsset(url: URL(filePath: "/tmp/turnip-browse-1.mov"))))
        let model = VideoLibraryViewModel(resolver: PhotoVideoResolver(imageManager: manager))

        model.select(StubAsset("asset-1"))
        await wait(until: { model.path.count == 1 }, "the first selection should reach the path")

        model.browse(to: StubAsset("asset-2"))
        await wait(until: { model.path.first?.assetIdentifier == "asset-2" }, "browsing should land")

        XCTAssertEqual(model.path.count, 1, "browsing must not grow the path")
        XCTAssertNil(model.path.first?.detectedClips, "a browsed-to neighbor has not been analyzed")
    }

    /// A browse that lands after the user already backed all the way out drops its result
    /// instead of pushing it back — the screen `browse(to:)` meant to replace is simply gone.
    func testABrowseThatFinishesAfterThePathEmptiedDropsItsResult() async {
        let manager = ScriptedImageManager(.asset(AVURLAsset(url: URL(filePath: "/tmp/turnip-browse-emptied.mov"))))
        let model = VideoLibraryViewModel(resolver: PhotoVideoResolver(imageManager: manager))

        model.select(StubAsset("asset-1"))
        await wait(until: { model.path.count == 1 }, "the first selection should reach the path")

        // `browse(to:)` only schedules a `Task`; it hasn't run yet when this call returns, so
        // emptying `path` here lands before the resolve completes every time.
        model.browse(to: StubAsset("asset-2"))
        model.path = []
        await wait(until: { model.resolution == nil }, "the browse should finish resolving")

        XCTAssertTrue(model.path.isEmpty, "a browse landing after the path emptied must not repush")
    }

    /// A cancelled PhotoKit request can still emit a tick or two, by which time the user has tapped
    /// something else. Without the identifier guard that late fraction would repaint whatever is
    /// being resolved now, so the assertion is that a painted ring survives a stale tick unchanged.
    func testATickFromAnAbandonedSelectionNeverPaintsTheNewOne() async throws {
        let manager = ScriptedImageManager(.silent)
        let model = VideoLibraryViewModel(resolver: PhotoVideoResolver(imageManager: manager))
        let current = StubAsset("current")

        model.select(StubAsset("abandoned"))
        await wait(until: { manager.requestCount == 1 }, "the first request should start")
        let abandonedTick = try XCTUnwrap(manager.reportProgress)
        model.cancelSelection()
        await wait(until: { model.resolution == nil }, "cancelling should end the resolution")

        model.select(current)
        await wait(until: { manager.requestCount == 2 }, "the second request should start")
        try XCTUnwrap(manager.reportProgress)(0.5)
        await wait(until: { model.downloadProgress(for: current) == 0.5 }, "the live tick paints")

        abandonedTick(0.9)
        // Each tick hands its write to the main actor as a fresh task; this hop is queued behind
        // the stale one, so by the time it returns the stale write has had its turn.
        await Task { @MainActor in }.value

        XCTAssertEqual(
            model.downloadProgress(for: current), 0.5,
            "a tick for a tile nobody is waiting on must not repaint the ring")
    }

    /// Spins the main actor until `condition` holds. `select(_:)` does its work in a `Task` the view
    /// model keeps private, so the published state is the only join point a test has.
    private func wait(
        until condition: () -> Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }
}

/// A `PHImageManager` the test scripts: it answers the video request the way the case under test
/// needs, and keeps the request's options so PhotoKit's progress handler can be fired on demand.
private final class ScriptedImageManager: PHImageManager, @unchecked Sendable {
    enum Reply {
        /// Never calls back — a request still in flight, which is also what PhotoKit is allowed to
        /// do with one that has been cancelled.
        case silent
        case asset(AVAsset)
        case failure(info: [AnyHashable: Any])
    }

    private let reply: Reply
    private let lock = NSLock()
    private var pendingOptions: PHVideoRequestOptions?
    private var _requestCount = 0

    init(_ reply: Reply) {
        self.reply = reply
        super.init()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    /// PhotoKit's progress handler for the most recent request, reduced to the one argument a test
    /// cares about. Nil before any request has started.
    var reportProgress: ((Double) -> Void)? {
        lock.lock()
        let handler = pendingOptions?.progressHandler
        lock.unlock()
        guard let handler else { return nil }
        return { fraction in
            var stop = ObjCBool(false)
            handler(fraction, nil, &stop, nil)
        }
    }

    override func requestAVAsset(
        forVideo asset: PHAsset,
        options: PHVideoRequestOptions?,
        resultHandler: @escaping (AVAsset?, AVAudioMix?, [AnyHashable: Any]?) -> Void
    ) -> PHImageRequestID {
        lock.lock()
        pendingOptions = options
        _requestCount += 1
        let requestID = PHImageRequestID(_requestCount)
        lock.unlock()

        switch reply {
        case .silent:
            break
        case .asset(let avAsset):
            resultHandler(avAsset, nil, nil)
        case .failure(let info):
            resultHandler(nil, nil, info)
        }
        return requestID
    }

    /// A scripted request has nothing to tear down, and the superclass has no request to find.
    override func cancelImageRequest(_ requestID: PHImageRequestID) {}
}

/// A `PHAsset` carrying only what the selection path reads off one.
private final class StubAsset: PHAsset, @unchecked Sendable {
    private let identifier: String
    private let seconds: TimeInterval

    init(_ identifier: String, duration: TimeInterval = 0) {
        self.identifier = identifier
        seconds = duration
        super.init()
    }

    override var localIdentifier: String { identifier }
    override var duration: TimeInterval { seconds }
}
