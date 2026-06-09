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
/// Implementation note: a `SingleFireContinuationGate` races the work task
/// against a sleep task. The first to call `resume` wins; the second is dropped.
/// The same gate backs `awaitValueUnlessCancelled` and the remote-image
/// data-URL races in `HTMLRemoteImageAttachmentFallback`.
func withSoftTimeout<T: Sendable>(
    seconds: TimeInterval,
    work: @escaping @Sendable () async -> T
) async -> T? {
    let timeoutNanoseconds = seconds * 1_000_000_000
    // A non-finite or overflowing deadline (e.g. `.greatestFiniteMagnitude`, which
    // callers use to mean "run to completion") can't be represented as `UInt64`
    // nanoseconds — `UInt64(.infinity)` traps at runtime. Treat any deadline that
    // doesn't fit as "no timeout" and just await the work.
    guard timeoutNanoseconds.isFinite, timeoutNanoseconds < Double(UInt64.max) else {
        return await work()
    }
    let sleepNanoseconds = UInt64(max(0, timeoutNanoseconds))

    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = SingleFireContinuationGate<T?>(continuation)

        Task {
            let value = await work()
            gate.resume(returning: value)
        }

        Task {
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            gate.resume(returning: nil)
        }
    }
}

/// Awaits `work` for up to `seconds`. If the deadline fires first, returns `nil`
/// immediately **and cancels** the `work` task.
///
/// This is the *hard* counterpart to `withSoftTimeout`. Use it on user-facing
/// paths where an operation must not run unbounded — e.g. a network recovery the
/// user is actively waiting on. It makes two guarantees:
///
/// 1. The caller is always unblocked within `seconds` (plus scheduling jitter),
///    regardless of whether `work` honors cancellation — the result is delivered
///    through a single-fire gate that the laggard task can no longer settle.
/// 2. On timeout, `work` is cancelled, so cooperative work is actually torn down
///    instead of leaking. In particular `URLSession.data(for:)` throws on Task
///    cancellation, so an in-flight request is cancelled rather than left running.
///    Work that ignores cancellation still finishes in the background, but its
///    result is discarded.
///
/// Prefer `withSoftTimeout` when the underlying work warms a shared cache and the
/// next caller should be able to reuse the in-flight result; prefer `withDeadline`
/// when re-attaching to stalled work would strand the caller (the canonical case
/// is `HTMLContentRecoveryService`'s Gmail fetch, whose in-flight dedup would
/// otherwise make every retry wait on the same hung request).
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    work: @escaping @Sendable () async -> T
) async -> T? {
    let timeoutNanoseconds = seconds * 1_000_000_000
    // A non-finite or overflowing deadline (e.g. `.greatestFiniteMagnitude`) can't
    // be represented as `UInt64` nanoseconds — `UInt64(.infinity)` traps at
    // runtime. Treat any deadline that doesn't fit as "no deadline" and just await.
    guard timeoutNanoseconds.isFinite, timeoutNanoseconds < Double(UInt64.max) else {
        return await work()
    }
    let sleepNanoseconds = UInt64(max(0, timeoutNanoseconds))

    // Hoisted out of the continuation so the timeout branch can cancel it.
    let workTask = Task { await work() }

    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = SingleFireContinuationGate<T?>(continuation)

        Task {
            let value = await workTask.value
            gate.resume(returning: value)
        }

        Task {
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            gate.resume(returning: nil)
            // No-op if `work` already won the race; otherwise propagates
            // cancellation into the abandoned work (e.g. a URLSession request).
            workTask.cancel()
        }
    }
}

/// Awaits `task.value`, but returns `cancellationValue` promptly if the *calling*
/// task is cancelled first — without cancelling `task`, which keeps running to
/// warm shared caches (the same soft semantics as `withSoftTimeout`). A plain
/// `await task.value` can't do this: it blocks until the task finishes even after
/// the caller has been cancelled.
///
/// Races task-completion against cancellation through a single-fire gate, so the
/// two producers can never double-resume the continuation. A cancellation that
/// fires before the continuation is installed is handled by `install` reporting
/// the already-settled value.
func awaitValueUnlessCancelled<T: Sendable>(
    of task: Task<T, Never>,
    cancellationValue: T
) async -> T {
    let gate = SingleFireContinuationGate<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            if let settled = gate.install(continuation) {
                continuation.resume(returning: settled)
                return
            }

            Task {
                gate.resume(returning: await task.value)
            }
        }
    } onCancel: {
        gate.resume(returning: cancellationValue)
    }
}

/// A thread-safe, single-fire bridge around a `CheckedContinuation<T, Never>`.
/// Multiple producers can race to settle it (work vs timeout, task-completion vs
/// cancellation); the first `resume(returning:)` wins and later calls are
/// dropped, so the continuation is resumed exactly once.
///
/// The continuation can be supplied at `init` (the common case where it already
/// exists) or installed later via `install` — for races where a producer such as
/// a cancellation handler may fire before the awaiting continuation is created.
final class SingleFireContinuationGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var settledValue: T?
    private var isSettled = false

    init() {}

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// Installs the awaiting continuation. Returns the winning value if the gate
    /// has already settled (so the caller resumes immediately); otherwise nil.
    func install(_ continuation: CheckedContinuation<T, Never>) -> T? {
        lock.lock()
        defer { lock.unlock() }

        guard !isSettled else {
            let value = settledValue
            settledValue = nil
            return value
        }

        self.continuation = continuation
        return nil
    }

    /// Settles the gate. The first call wins; later calls are dropped.
    func resume(returning value: T) {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        let continuation = self.continuation
        if continuation == nil {
            settledValue = value
        } else {
            settledValue = nil
        }
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }
}
