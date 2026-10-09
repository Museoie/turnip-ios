import AVFoundation
import Photos
import XCTest
@testable import Turnip

/// A `PHImageManager` whose video request never calls back — the shape PhotoKit is allowed to take
/// after a cancellation — so these tests prove the resolver's cancellation bridge resumes on its
/// own rather than waiting for a callback that will never come.
private final class SilentImageManager: PHImageManager, @unchecked Sendable {
    static let requestID: PHImageRequestID = 42

    private let lock = NSLock()
    private var _cancelledIDs: [PHImageRequestID] = []
    /// Fulfilled when `requestAVAsset` has been called, so a test can cancel *after* the request
    /// is in flight.
    let requestStarted = XCTestExpectation(description: "requestAVAsset called")

    var cancelledIDs: [PHImageRequestID] {
        lock.lock()
        defer { lock.unlock() }
        return _cancelledIDs
    }

    override func requestAVAsset(
        forVideo asset: PHAsset,
        options: PHVideoRequestOptions?,
        resultHandler: @escaping (AVAsset?, AVAudioMix?, [AnyHashable: Any]?) -> Void
    ) -> PHImageRequestID {
        requestStarted.fulfill()
        return Self.requestID
    }

    override func cancelImageRequest(_ requestID: PHImageRequestID) {
        lock.lock()
        _cancelledIDs.append(requestID)
        lock.unlock()
    }
}

/// A `PHImageManager` that answers the video request synchronously with a scripted
/// `(AVAsset?, info)` pair, optionally preceded by iCloud download ticks. The silent stub above
/// never calls back at all, which is why nothing else exercises what the resolver makes of a
/// request that actually *finishes*.
private final class CallbackImageManager: PHImageManager, @unchecked Sendable {
    private let avAsset: AVAsset?
    private let info: [AnyHashable: Any]?
    private let downloadTicks: [Double]

    init(avAsset: AVAsset? = nil, info: [AnyHashable: Any]? = nil, downloadTicks: [Double] = []) {
        self.avAsset = avAsset
        self.info = info
        self.downloadTicks = downloadTicks
        super.init()
    }

    /// PhotoKit reports a failure through the info dictionary, not by withholding a callback, so
    /// every failure case is "no asset, plus this error under `PHImageErrorKey`".
    static func failing(with error: Error, downloadTicks: [Double] = []) -> CallbackImageManager {
        CallbackImageManager(info: [PHImageErrorKey: error], downloadTicks: downloadTicks)
    }

    override func requestAVAsset(
        forVideo asset: PHAsset,
        options: PHVideoRequestOptions?,
        resultHandler: @escaping (AVAsset?, AVAudioMix?, [AnyHashable: Any]?) -> Void
    ) -> PHImageRequestID {
        for tick in downloadTicks {
            var stop = ObjCBool(false)
            options?.progressHandler?(tick, nil, &stop, nil)
        }
        resultHandler(avAsset, nil, info)
        return 1
    }
}

/// A `PHImageManager` that behaves like PhotoKit for an iCloud-only slow-mo clip: one download
/// tick, then an `AVComposition` (no URL to hand back), then a failed export session — so the
/// test observes the full `.downloading` → `.exporting` event sequence on the failure path.
private final class CompositionImageManager: PHImageManager, @unchecked Sendable {
    private let lock = NSLock()
    private var _exportRequested = false
    var exportRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _exportRequested
    }

    override func requestAVAsset(
        forVideo asset: PHAsset,
        options: PHVideoRequestOptions?,
        resultHandler: @escaping (AVAsset?, AVAudioMix?, [AnyHashable: Any]?) -> Void
    ) -> PHImageRequestID {
        // The iCloud download finishing, then Photos handing back a composition.
        var stop = ObjCBool(false)
        options?.progressHandler?(0.5, nil, &stop, nil)
        resultHandler(AVMutableComposition(), nil, nil)
        return 7
    }

    override func requestExportSession(
        forVideo asset: PHAsset,
        options: PHVideoRequestOptions?,
        exportPreset: String,
        resultHandler: @escaping (AVAssetExportSession?, [AnyHashable: Any]?) -> Void
    ) -> PHImageRequestID {
        lock.lock()
        _exportRequested = true
        lock.unlock()
        // PhotoKit reuses the same request options — progress handler included — for the export
        // session request, so a download tick can arrive *after* `.exporting` was already
        // emitted. The resolver forwards it faithfully; the view model owns the phase policy.
        var stop = ObjCBool(false)
        options?.progressHandler?(0.9, nil, &stop, nil)
        // No session: the export fails the way a genuinely failed export does.
        resultHandler(nil, nil)
        return 8
    }
}

/// A `PHImageManager` that behaves like PhotoKit for an iCloud plain recording: one download
/// tick, then the `AVURLAsset` itself — the path that must never report an export phase.
private final class DirectURLImageManager: PHImageManager, @unchecked Sendable {
    override func requestAVAsset(
        forVideo asset: PHAsset,
        options: PHVideoRequestOptions?,
        resultHandler: @escaping (AVAsset?, AVAudioMix?, [AnyHashable: Any]?) -> Void
    ) -> PHImageRequestID {
        var stop = ObjCBool(false)
        options?.progressHandler?(0.5, nil, &stop, nil)
        resultHandler(AVURLAsset(url: URL(filePath: "/tmp/turnip-test-direct.mov")), nil, nil)
        return 9
    }
}

/// Collects `ResolutionProgress` events from the resolver's `@Sendable` progress closure; PhotoKit
/// makes no thread promise for its own callback, so the log guards the array.
private final class ProgressEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ResolutionProgress] = []
    var events: [ResolutionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func append(_ event: ResolutionProgress) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }
}

final class PhotoVideoResolverTests: XCTestCase {
    private enum Outcome {
        case finished(Result<AVURLAsset, Error>)
        case timedOut
    }

    /// Cancellation before the continuation exists: `withTaskCancellationHandler` runs its handler
    /// immediately for an already-cancelled task, ahead of the operation closure. The resolver must
    /// still throw `CancellationError` promptly instead of parking a continuation forever.
    func testResolveThrowsCancellationWhenTaskIsCancelledBeforeRequestStarts() async {
        let manager = SilentImageManager()
        let resolver = PhotoVideoResolver(imageManager: manager)

        let task = Task<AVURLAsset, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await resolver.resolve(PHAsset()) { _ in }
        }

        let outcome = await Self.outcome(of: task, timeoutSeconds: 5)
        guard case .finished(.failure(let error)) = outcome else {
            return XCTFail("expected CancellationError, got \(outcome)")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        XCTAssertEqual(
            manager.cancelledIDs,
            [SilentImageManager.requestID],
            "the issued request should be cancelled once its ID is known"
        )
    }

    /// Cancellation after the request is in flight, with PhotoKit never calling back: the
    /// cancellation handler itself must resume the continuation.
    func testResolveThrowsCancellationWhenCancelledMidFlightWithoutCallback() async {
        let manager = SilentImageManager()
        let resolver = PhotoVideoResolver(imageManager: manager)

        let task = Task<AVURLAsset, Error> {
            try await resolver.resolve(PHAsset()) { _ in }
        }
        await fulfillment(of: [manager.requestStarted], timeout: 5)
        task.cancel()

        let outcome = await Self.outcome(of: task, timeoutSeconds: 5)
        guard case .finished(.failure(let error)) = outcome else {
            return XCTFail("expected CancellationError, got \(outcome)")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        XCTAssertEqual(manager.cancelledIDs, [SilentImageManager.requestID])
    }

    // MARK: - Resolving a request that finishes

    /// The contract is that PhotoKit's own `AVURLAsset` is handed on, not rebuilt from its URL:
    /// that object is what carries read access to a file inside the Photos container.
    func testResolveReturnsPhotoKitsURLAssetItselfRatherThanACopy() async throws {
        let photoKitAsset = AVURLAsset(url: URL(filePath: "/tmp/turnip-resolve-identity.mov"))
        let resolver = PhotoVideoResolver(imageManager: CallbackImageManager(avAsset: photoKitAsset))

        let resolved = try await resolver.resolve(PHAsset()) { _ in }

        XCTAssertTrue(resolved === photoKitAsset, "the asset must not be rebuilt from its URL")
    }

    /// PhotoKit flags a cancelled request in its info dictionary rather than as an error. That has
    /// to stay a `CancellationError`: as a `VideoResolutionError` it would put an error banner in
    /// front of a user who backed out on purpose.
    func testResolveThrowsCancellationWhenPhotoKitFlagsTheRequestCancelled() async {
        let manager = CallbackImageManager(info: [PHImageCancelledKey: true])
        let resolver = PhotoVideoResolver(imageManager: manager)

        do {
            _ = try await resolver.resolve(PHAsset()) { _ in }
            XCTFail("expected the resolve to throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    // MARK: - Failure classification

    /// A URL-loading failure is the shape a dead connection takes, and it names iCloud even when
    /// PhotoKit never got far enough to report a single download tick.
    func testAURLLoadingFailureIsAnICloudDownloadFailure() async throws {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let outcome = await classifyFailure(of: CallbackImageManager.failing(with: error))
        let failure = try XCTUnwrap(outcome)

        XCTAssertEqual(failure.classification, .iCloudDownloadFailed)
        XCTAssertEqual((failure.underlying as? NSError)?.domain, NSURLErrorDomain)
        XCTAssertEqual((failure.underlying as? NSError)?.code, NSURLErrorNotConnectedToInternet)
    }

    /// Photos reports a failed iCloud fetch under its own domain too, with two distinct codes.
    /// Both mean the download failed; any other code under the same domain does not, which is the
    /// half of the check a domain-only test would leave free to regress.
    func testOnlyPhotosOwnNetworkCodesCountAsICloudDownloadFailures() async throws {
        let cases: [(Int, Classification)] = [
            (PHPhotosError.Code.networkAccessRequired.rawValue, .iCloudDownloadFailed),
            (PHPhotosError.Code.networkError.rawValue, .iCloudDownloadFailed),
            (PHPhotosError.Code.invalidResource.rawValue, .unavailable)
        ]

        for (code, expected) in cases {
            let error = NSError(domain: PHPhotosErrorDomain, code: code)
            let manager = CallbackImageManager.failing(with: error)
            let outcome = await classifyFailure(of: manager)
            let failure = try XCTUnwrap(outcome)
            XCTAssertEqual(failure.classification, expected, "PHPhotosError code \(code)")
        }
    }

    /// A local read failure with no download in sight is not a connectivity problem: telling the
    /// user to check their connection would send them chasing the wrong thing.
    func testALocalFailureWithNoDownloadInSightIsUnavailable() async throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let outcome = await classifyFailure(of: CallbackImageManager.failing(with: error))
        let failure = try XCTUnwrap(outcome)

        XCTAssertEqual(failure.classification, .unavailable)
    }

    /// The very same error, once PhotoKit has reported download progress, *is* a download failure.
    /// The download flag is the only thing separating this from the case above, so the two only
    /// mean anything as a pair.
    func testTheSameFailureAfterADownloadTickBlamesICloud() async throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let manager = CallbackImageManager.failing(with: error, downloadTicks: [0.3])
        let outcome = await classifyFailure(of: manager)
        let failure = try XCTUnwrap(outcome)

        XCTAssertEqual(failure.classification, .iCloudDownloadFailed)
    }

    /// Photos can return nothing and say nothing — an asset deleted mid-flight, an unsupported
    /// format. There is no underlying error to carry and nothing to blame on the network.
    func testAFailureWithNoInfoAtAllIsUnavailableWithNoUnderlyingError() async throws {
        let outcome = await classifyFailure(of: CallbackImageManager())
        let failure = try XCTUnwrap(outcome)

        XCTAssertEqual(failure.classification, .unavailable)
        XCTAssertNil(failure.underlying)
    }

    // MARK: - Error copy

    /// Three cases because there are three different things the user can do about a failure: retry
    /// on a better connection, retry at all, or give up on this video.
    func testEachResolutionErrorCarriesItsOwnMessage() {
        XCTAssertEqual(
            VideoResolutionError.iCloudDownloadFailed(underlying: nil).errorDescription,
            "Couldn't download this video from iCloud. Check your connection and try again.")
        XCTAssertEqual(
            VideoResolutionError.exportFailed(underlying: nil).errorDescription,
            "Couldn't prepare this video for analysis.")
        XCTAssertEqual(
            VideoResolutionError.unavailable(underlying: nil).errorDescription,
            "This video isn't available.")
    }

    /// An underlying error is appended, never substituted: the system's own copy ("the operation
    /// couldn't be completed") is the part that tells the user nothing.
    func testAnUnderlyingErrorIsAppendedToTheMessageRatherThanReplacingIt() throws {
        let underlying = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        let plain = try XCTUnwrap(VideoResolutionError.unavailable(underlying: nil).errorDescription)
        let annotated = try XCTUnwrap(
            VideoResolutionError.unavailable(underlying: underlying).errorDescription)

        XCTAssertEqual(annotated, "\(plain) (The request timed out.)")
    }

    // MARK: - Resolution progress phases

    /// The composition path emits `.downloading` for the iCloud phase and `.exporting` immediately
    /// before the export starts — and `.exporting` still arrives when the export itself fails, so
    /// a failed export can't leave the UI parked on the download bar either. A download tick that
    /// PhotoKit reports for the export request itself arrives after `.exporting`; the resolver
    /// forwards it untouched — the view model, not the resolver, owns the phase policy (see
    /// `testResolutionDropsDownloadingEventsAfterExporting`).
    func testResolveEmitsDownloadingThenExportingForCompositionAsset() async {
        let manager = CompositionImageManager()
        let resolver = PhotoVideoResolver(imageManager: manager)
        let log = ProgressEventLog()

        do {
            _ = try await resolver.resolve(PHAsset()) { log.append($0) }
            XCTFail("expected the export to fail")
        } catch let error as VideoResolutionError {
            guard case .exportFailed = error else {
                return XCTFail("expected exportFailed, got \(error)")
            }
        } catch {
            return XCTFail("expected VideoResolutionError, got \(error)")
        }

        XCTAssertEqual(log.events, [.downloading(0.5), .exporting, .downloading(0.9)])
        XCTAssertTrue(manager.exportRequested, "the export must actually run after .exporting")
    }

    /// Assets that resolve to a URL never take the export path, so no `.exporting` event may be
    /// emitted for them — the determinate download bar belongs to the download alone.
    func testResolveNeverEmitsExportingForDirectURLAsset() async throws {
        let resolver = PhotoVideoResolver(imageManager: DirectURLImageManager())
        let log = ProgressEventLog()

        let asset = try await resolver.resolve(PHAsset()) { log.append($0) }

        XCTAssertEqual(asset.url.lastPathComponent, "turnip-test-direct.mov")
        XCTAssertEqual(log.events, [.downloading(0.5)])
    }

    /// The phase is monotonic at the view-model layer: once `.exporting` lands, a late
    /// `.downloading` tick — the reused request options reporting for the export request, or a
    /// `Task` hop landing out of order — must not flip the rendered fraction back to a
    /// determinate bar. A per-event overwrite would render this sequence as
    /// `[0.5, nil, 0.9]`; it must stay `[0.5, nil, nil]`, with the banner on
    /// "Preparing video…" for the rest of the export.
    func testResolutionDropsDownloadingEventsAfterExporting() {
        var resolution = VideoLibraryViewModel.Resolution(
            assetIdentifier: "asset-1", downloadProgress: nil)
        var fractions: [Double?] = []
        for event in [ResolutionProgress.downloading(0.5), .exporting, .downloading(0.9)] {
            resolution.apply(event)
            fractions.append(resolution.downloadProgress)
        }

        XCTAssertEqual(fractions, [0.5, nil, nil])
    }

    // MARK: - Temporary export cleanup

    /// `deleteTemporaryExport(for:)` removes a composition export the resolver created:
    /// filename prefix plus directly inside tmp/.
    func testDeleteTemporaryExportRemovesResolverCreatedFile() {
        let url = URL.temporaryDirectory.appending(
            path: "\(PhotoVideoResolver.temporaryExportFilenamePrefix)\(UUID().uuidString).mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        defer { try? FileManager.default.removeItem(at: url) }

        PhotoVideoResolver.deleteTemporaryExport(for: AVURLAsset(url: url))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The guard must discriminate on location, not just the name: a prefixed file *outside*
    /// tmp/ is never deleted. Deleting the wrong file here would mean corrupting the user's
    /// Photos library, so this is the test that earns the guard.
    func testDeleteTemporaryExportKeepsPrefixedFileOutsideTemporaryDirectory() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(
            path: "\(PhotoVideoResolver.temporaryExportFilenamePrefix)\(UUID().uuidString).mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))

        PhotoVideoResolver.deleteTemporaryExport(for: AVURLAsset(url: url))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "must not delete files outside tmp/, whatever their name")
    }

    /// A non-export temp file is left alone — the cleanup is not a license to empty tmp/.
    func testDeleteTemporaryExportKeepsUnprefixedFileInTemporaryDirectory() {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        defer { try? FileManager.default.removeItem(at: url) }

        PhotoVideoResolver.deleteTemporaryExport(for: AVURLAsset(url: url))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// The launch sweep removes orphaned exports and leaves everything else in tmp/ alone.
    func testDeleteOrphanedTemporaryExportsSweepsOnlyPrefixedFiles() {
        let orphan = URL.temporaryDirectory.appending(
            path: "\(PhotoVideoResolver.temporaryExportFilenamePrefix)\(UUID().uuidString).mov")
        let innocent = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: orphan.path, contents: Data("x".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: innocent.path, contents: Data("x".utf8)))
        defer {
            try? FileManager.default.removeItem(at: orphan)
            try? FileManager.default.removeItem(at: innocent)
        }

        PhotoVideoResolver.deleteOrphanedTemporaryExports(olderThan: Date())

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: innocent.path))
    }

    /// The sweep must not race in-flight resolutions: an export this session writes while the
    /// detached sweep is still running is created after the launch timestamp, so it survives.
    func testDeleteOrphanedTemporaryExportsKeepsFilesCreatedAfterLaunch() {
        let fileManager = FileManager.default
        let orphan = URL.temporaryDirectory.appending(
            path: "\(PhotoVideoResolver.temporaryExportFilenamePrefix)\(UUID().uuidString).mov")
        XCTAssertTrue(fileManager.createFile(atPath: orphan.path, contents: Data("x".utf8)))
        // Pin the orphan to a previous session explicitly; creation-time granularity is not
        // something this test should depend on.
        try? fileManager.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: orphan.path)
        let launchDate = Date()
        let inFlight = URL.temporaryDirectory.appending(
            path: "\(PhotoVideoResolver.temporaryExportFilenamePrefix)\(UUID().uuidString).mov")
        XCTAssertTrue(fileManager.createFile(atPath: inFlight.path, contents: Data("x".utf8)))
        defer {
            try? fileManager.removeItem(at: orphan)
            try? fileManager.removeItem(at: inFlight)
        }

        PhotoVideoResolver.deleteOrphanedTemporaryExports(olderThan: launchDate)

        XCTAssertFalse(
            fileManager.fileExists(atPath: orphan.path),
            "an export orphaned by a previous session is still swept")
        XCTAssertTrue(
            fileManager.fileExists(atPath: inFlight.path),
            "an export written after launch must survive the sweep")
    }

    /// Which `VideoResolutionError` case came back. The error itself can't be `Equatable` — it
    /// carries an arbitrary underlying `Error` — so the case is compared on its own.
    private enum Classification: Equatable {
        case iCloudDownloadFailed, exportFailed, unavailable
    }

    private struct Failure {
        let classification: Classification
        let underlying: Error?
    }

    /// Resolves against `manager` and reports how the failure was classified, failing the test if
    /// the resolve unexpectedly succeeds or throws something other than a `VideoResolutionError`.
    private func classifyFailure(
        of manager: PHImageManager, file: StaticString = #filePath, line: UInt = #line
    ) async -> Failure? {
        do {
            _ = try await PhotoVideoResolver(imageManager: manager).resolve(PHAsset()) { _ in }
            XCTFail("expected the resolve to throw", file: file, line: line)
        } catch let error as VideoResolutionError {
            switch error {
            case .iCloudDownloadFailed(let underlying):
                return Failure(classification: .iCloudDownloadFailed, underlying: underlying)
            case .exportFailed(let underlying):
                return Failure(classification: .exportFailed, underlying: underlying)
            case .unavailable(let underlying):
                return Failure(classification: .unavailable, underlying: underlying)
            }
        } catch {
            XCTFail("expected VideoResolutionError, got \(error)", file: file, line: line)
        }
        return nil
    }

    /// Races `task` against a timeout so a leaked continuation fails the test instead of hanging it.
    ///
    /// Not a task group: awaiting a stuck task's `result` cannot be cancelled, and a group waits for
    /// all its children before returning, so a leak would hang the group too. Whichever side
    /// finishes first resumes the continuation; the loser is simply abandoned.
    private static func outcome(of task: Task<AVURLAsset, Error>, timeoutSeconds: UInt64) async -> Outcome {
        let once = OnceFlag()
        return await withCheckedContinuation { continuation in
            Task {
                let result = await task.result
                if once.claim() { continuation.resume(returning: .finished(result)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }
}

/// First `claim()` returns true, every later one false — so exactly one racer resumes the continuation.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
