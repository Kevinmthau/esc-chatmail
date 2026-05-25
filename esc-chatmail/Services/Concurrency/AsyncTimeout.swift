import Foundation

/// Awaits `work` for up to `seconds`. If the timeout fires first, returns `nil`
/// immediately while leaving `work` running in the background.
///
/// This is a *soft* timeout — `work` is **not** cancelled. Use it for operations
/// that warm shared caches and don't reliably honor cooperative cancellation
/// (the canonical case in this app is `await task.value` on a cached
/// `Task<_, Never>` that fans out network calls). Letting the underlying work
/// finish on its own preserves the cache so the next caller can succeed quickly.
///
/// If you need real cancellation, do not use this helper — spawn a `Task`
/// directly and check `Task.isCancelled` inside `work` instead.
///
/// Implementation note: a single-fire continuation gate races the work task
/// against a sleep task. The first to call `resume` wins; the second is
/// dropped. Mirrors `HTMLRemoteImageAttachmentFallback.ResolutionGate` and the
/// `racedResolvedDataURL` usage pattern.
func withSoftTimeout<T: Sendable>(
    seconds: TimeInterval,
    work: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = SoftTimeoutGate<T?>(continuation)

        Task {
            let value = await work()
            gate.resume(returning: value)
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gate.resume(returning: nil)
        }
    }
}

private final class SoftTimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(returning result: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: result)
    }
}
