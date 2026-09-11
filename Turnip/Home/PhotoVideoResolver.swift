import AVFoundation
import Foundation
import Photos

/// Why a picked video couldn't be turned into a readable asset. Deliberately separate from
/// `PoseDiagnosticError` (and from whatever the pipeline will throw): a failed iCloud download is a
/// connectivity problem the user can fix, not an analysis failure, and the UI should say so.
enum VideoResolutionError: LocalizedError {
    /// The asset lives only in iCloud ("Optimize iPhone Storage") and fetching it failed — no
    /// network, iCloud signed out, download interrupted.
    case iCloudDownloadFailed(underlying: Error?)
    /// Photos handed back a composition (slow-mo, edited) and exporting it to a file failed.
    case exportFailed(underlying: Error?)
    /// Photos returned nothing and gave no reason (asset deleted mid-flight, unsupported format).
    case unavailable(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .iCloudDownloadFailed(let underlying):
            return Self.describe("Couldn't download this video from iCloud. Check your connection and try again.", underlying)
        case .exportFailed(let underlying):
            return Self.describe("Couldn't prepare this video for analysis.", underlying)
        case .unavailable(let underlying):
            return Self.describe("This video isn't available.", underlying)
        }
    }

    private static func describe(_ message: String, _ underlying: Error?) -> String {
        guard let underlying else { return message }
        return "\(message) (\(underlying.localizedDescription))"
    }
}

/// Resolves a `PHAsset` to an `AVURLAsset` the pipeline can read.
///
/// The common case is free: Photos returns an `AVURLAsset` for ordinary recordings, and that object
/// is handed on as-is — not reduced to its URL. The file lives inside the Photos container, and it is
/// the object PhotoKit returned that carries read access to it; a fresh `AVURLAsset(url:)` on the
/// same path is not guaranteed to open. Two slower paths:
///
/// - **iCloud-only assets.** `isNetworkAccessAllowed` is on, so Photos downloads first and reports
///   through `onProgress`; the caller shows that progress because a multi-hundred-MB download on
///   cellular is not instant. Failures surface as `.iCloudDownloadFailed`, not a generic error.
/// - **Compositions.** Slow-motion and edited videos come back as `AVComposition`s, which have no
///   URL. Those are exported to a temp file and returned as an `AVURLAsset` on that file.
///
/// Task cancellation cancels the in-flight PhotoKit request or export.
struct PhotoVideoResolver {
    var imageManager: PHImageManager = .default()

    func resolve(_ asset: PHAsset, onProgress: @escaping @Sendable (Double) -> Void) async throws -> AVURLAsset {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        // The pipeline crops from the full frame, so never accept a downscaled iCloud rendition.
        options.deliveryMode = .highQualityFormat
        // PhotoKit only calls this while downloading from iCloud, which is also how we know a
        // subsequent failure was a download failure rather than a local one.
        let sawDownload = DownloadFlag()
        options.progressHandler = { progress, _, _, _ in
            sawDownload.set()
            onProgress(progress)
        }

        let avAsset: AVAsset = try await request(errorKind: { underlying in
            sawDownload.value || Self.looksLikeNetworkError(underlying)
                ? .iCloudDownloadFailed(underlying: underlying)
                : .unavailable(underlying: underlying)
        }) { handler in
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                handler(avAsset, info)
            }
        }

        if let urlAsset = avAsset as? AVURLAsset {
            return urlAsset
        }
        // Don't start an export the user has already backed out of.
        try Task.checkCancellation()
        return try await export(asset, options: options)
    }

    // MARK: - Composition export

    private func export(_ asset: PHAsset, options: PHVideoRequestOptions) async throws -> AVURLAsset {
        // Not passthrough: slow-mo compositions carry time-scaled segments that passthrough can't
        // re-mux, so this re-encodes. Slower, but it works for every composition Photos produces.
        let session: AVAssetExportSession = try await request(errorKind: { .exportFailed(underlying: $0) }) { handler in
            imageManager.requestExportSession(
                forVideo: asset, options: options, exportPreset: AVAssetExportPresetHighestQuality
            ) { session, info in
                handler(session, info)
            }
        }

        let outputURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false

        let cancellable = ExportCancellation(session: session)
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            cancellable.cancel()
        }

        switch session.status {
        case .completed:
            return AVURLAsset(url: outputURL)
        case .cancelled:
            throw CancellationError()
        default:
            throw VideoResolutionError.exportFailed(underlying: session.error)
        }
    }

    // MARK: - PhotoKit request → async

    /// Bridges one PhotoKit callback-style request into async/await, honoring task cancellation.
    /// `start` kicks off the request and returns its ID; the handler it's given receives the
    /// result and PhotoKit's info dictionary.
    private func request<T>(
        errorKind: @escaping (Error?) -> VideoResolutionError,
        _ start: (@escaping (T?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID
    ) async throws -> T {
        let box = RequestBox<T>(imageManager: imageManager)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.store(continuation)
                let requestID = start { value, info in
                    box.resume(with: Self.result(value: value, info: info, errorKind: errorKind))
                }
                box.began(requestID)
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func result<T>(
        value: T?, info: [AnyHashable: Any]?, errorKind: (Error?) -> VideoResolutionError
    ) -> Result<T, Error> {
        if let value {
            return .success(value)
        }
        if (info?[PHImageCancelledKey] as? Bool) == true {
            return .failure(CancellationError())
        }
        return .failure(errorKind(info?[PHImageErrorKey] as? Error))
    }

    /// PhotoKit reports a failed iCloud fetch either as a URL-loading error or as one of two
    /// `PHPhotosError` codes; neither is surfaced as a typed "download failed".
    private static func looksLikeNetworkError(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.domain == NSURLErrorDomain { return true }
        guard error.domain == PHPhotosErrorDomain else { return false }
        return error.code == PHPhotosError.Code.networkAccessRequired.rawValue
            || error.code == PHPhotosError.Code.networkError.rawValue
    }
}

/// `AVAssetExportSession` isn't `Sendable`, but `cancelExport()` is documented as callable from any
/// thread; this wrapper is what the `@Sendable` cancellation handler captures.
private struct ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession

    func cancel() {
        session.cancelExport()
    }
}

/// Set once from PhotoKit's progress callback, read from the result handler — possibly on
/// different threads, hence the lock.
private final class DownloadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// Holds the continuation and request ID for one in-flight PhotoKit request so it is resumed
/// exactly once, from whichever arrives first: the result handler, or task cancellation. Guards
/// against PhotoKit calling the handler after cancellation (or not at all — the docs don't promise
/// a callback for a cancelled request, so cancellation resumes the continuation itself).
///
/// Cancellation can also arrive *before* the continuation exists: `withTaskCancellationHandler`
/// runs its handler immediately when the task is already cancelled on entry, ahead of the
/// operation closure. `store` handles that case by resuming straight away instead of parking a
/// continuation that nothing would ever resume.
private final class RequestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let imageManager: PHImageManager
    private var continuation: CheckedContinuation<T, Error>?
    private var requestID: PHImageRequestID?
    private var isCancelled = false

    init(imageManager: PHImageManager) {
        self.imageManager = imageManager
    }

    func store(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        let cancelled = isCancelled
        if !cancelled {
            self.continuation = continuation
        }
        lock.unlock()
        if cancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Records the request ID once PhotoKit returns it. If cancellation already happened (a race
    /// the result handler can't see), cancel the request now that we finally have its ID.
    func began(_ requestID: PHImageRequestID) {
        lock.lock()
        self.requestID = requestID
        let cancelNow = isCancelled
        lock.unlock()
        if cancelNow {
            imageManager.cancelImageRequest(requestID)
        }
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let requestID = self.requestID
        lock.unlock()
        if let requestID {
            imageManager.cancelImageRequest(requestID)
        }
        resume(with: .failure(CancellationError()))
    }
}
