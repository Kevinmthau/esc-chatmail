import Foundation
@testable import esc_chatmail

/// Deterministic `SyncClock` for tests: `sleep` returns immediately (advancing
/// virtual time and recording the requested duration) instead of suspending,
/// and honors task cancellation exactly like the real `Task.sleep`.
final class FakeSyncClock: SyncClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _sleeps: [UInt64] = []

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        _now = now
    }

    /// Every `sleep(nanoseconds:)` request, in call order.
    var sleeps: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return _sleeps
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _now = _now.addingTimeInterval(interval)
    }

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        lock.withLock {
            _sleeps.append(nanoseconds)
            _now = _now.addingTimeInterval(TimeInterval(nanoseconds) / 1_000_000_000)
        }
        // Yield so cooperatively scheduled work interleaves the way a real
        // suspension point would, without consuming wall time.
        await Task.yield()
        try Task.checkCancellation()
    }
}
