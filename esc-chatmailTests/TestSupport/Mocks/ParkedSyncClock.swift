import Foundation
@testable import esc_chatmail

/// `SyncClock` whose `sleep` never elapses: it records the requested duration
/// and suspends until the calling task is cancelled, then throws
/// `CancellationError` like the real `Task.sleep`. Use it where a deadline
/// must not fire during the test (the opposite of `FakeSyncClock`, whose
/// sleeps return at once). Never consumes wall time.
final class ParkedSyncClock: SyncClock, @unchecked Sendable {
    /// `lock` guards `_sleeps` and `parked`.
    private let lock = NSLock()
    private var _sleeps: [UInt64] = []
    private var parked: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Every `sleep(nanoseconds:)` request, in call order.
    var sleeps: [UInt64] {
        lock.withLock { _sleeps }
    }

    func now() -> Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    func sleep(nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let isCancelled = lock.withLock { () -> Bool in
                    _sleeps.append(nanoseconds)
                    if Task.isCancelled {
                        return true
                    }
                    parked[id] = continuation
                    return false
                }
                if isCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = lock.withLock { parked.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
