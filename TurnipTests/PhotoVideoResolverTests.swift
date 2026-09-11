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
        XCTAssertEqual(manager.cancelledIDs, [SilentImageManager.requestID], "the issued request should be cancelled once its ID is known")
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
