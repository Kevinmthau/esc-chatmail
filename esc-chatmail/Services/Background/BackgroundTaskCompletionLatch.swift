import Foundation
import os

/// One linearization point shared by expiration-sensitive scheduling and task
/// completion. Once expiration wins, later submissions are rejected and later
/// completion is forced to failure by the same atomic state transition.
final class BackgroundTaskLifecycleState: @unchecked Sendable {
    private struct State {
        var didComplete = false
        var didExpire = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func expire() {
        state.withLock { state in
            guard !state.didComplete else { return }
            state.didExpire = true
        }
    }

    func complete(success: Bool) -> Bool? {
        completeReportingExpiry(success: success)?.reported
    }

    /// `complete(success:)`, also saying whether expiration had won: the result iOS is
    /// given and the reason for it come from the one transition, so a record of the run
    /// cannot disagree with what was reported.
    func completeReportingExpiry(success: Bool) -> (reported: Bool, didExpire: Bool)? {
        state.withLock { state -> (reported: Bool, didExpire: Bool)? in
            guard !state.didComplete else { return nil }
            state.didComplete = true
            return (success && !state.didExpire, state.didExpire)
        }
    }

    @discardableResult
    func submitIfActive(_ submission: () -> Void) -> Bool {
        state.withLock { state in
            guard !state.didExpire, !state.didComplete else { return false }
            submission()
            return true
        }
    }
}

/// Ensures a background task's completion callback runs exactly once after its
/// worker has unwound. Expiration records a forced failure but deliberately
/// does not complete immediately: iOS may suspend the process as soon as
/// `setTaskCompleted` returns, before cancellation cleanup has finished.
final class BackgroundTaskCompletionLatch: @unchecked Sendable {
    private let lifecycleState: BackgroundTaskLifecycleState
    private let onComplete: (Bool) -> Void

    init(
        lifecycleState: BackgroundTaskLifecycleState = BackgroundTaskLifecycleState(),
        onComplete: @escaping (Bool) -> Void
    ) {
        self.lifecycleState = lifecycleState
        self.onComplete = onComplete
    }

    func expire() {
        lifecycleState.expire()
    }

    func complete(success: Bool) {
        complete(success: success, beforeReporting: nil)
    }

    /// Completes once, first calling `beforeReporting` with what iOS is about to be told and
    /// whether expiration won. It runs before `onComplete` because iOS may suspend the
    /// process as soon as `setTaskCompleted` returns: a record written after it, or from the
    /// expiration handler, could be lost (`BackgroundRunJournal`). Nothing in it may wait.
    func complete(success: Bool, beforeReporting: ((_ reported: Bool, _ didExpire: Bool) -> Void)?) {
        guard let result = lifecycleState.completeReportingExpiry(success: success) else { return }
        beforeReporting?(result.reported, result.didExpire)
        onComplete(result.reported)
    }
}

/// Holds a newly-created Swift worker until its cancellation closure has been
/// registered. A `Task` starts eagerly, so without this handshake an expiration
/// remembered before registration could arrive only after real sync work had
/// already begun.
final class BackgroundTaskWorkerStartGate: @unchecked Sendable {
    private struct State {
        var isOpen = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func waitUntilOpen() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state -> Bool in
                guard !state.isOpen else { return true }
                precondition(state.waiter == nil, "Background task start gate supports one worker")
                state.waiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.isOpen else { return nil }
            state.isOpen = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    var hasWaitingWorker: Bool {
        state.withLock { !$0.isOpen && $0.waiter != nil }
    }
}

/// Linearizes post-run scheduling with `BGTask` expiration. If expiration wins
/// the lock, no retry or escalation can be submitted afterwards; if a submit
/// wins, it completes before expiration is recorded.
final class BackgroundTaskSchedulingGate: @unchecked Sendable {
    private let lifecycleState: BackgroundTaskLifecycleState

    init(lifecycleState: BackgroundTaskLifecycleState = BackgroundTaskLifecycleState()) {
        self.lifecycleState = lifecycleState
    }

    func expire() {
        lifecycleState.expire()
    }

    @discardableResult
    func submitIfActive(_ submission: () -> Void) -> Bool {
        lifecycleState.submitIfActive(submission)
    }
}

/// Bridges the ordering gap between installing a `BGTask` expiration handler
/// and creating its Swift worker task. An expiration that arrives first is
/// remembered; installing the worker's cancellation closure then invokes it
/// immediately instead of losing the cancellation.
final class BackgroundTaskCancellationLatch: @unchecked Sendable {
    private struct State {
        var didExpire = false
        var cancelWorker: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(cancelWorker: @escaping @Sendable () -> Void) {
        let shouldCancel = state.withLock { state -> Bool in
            guard !state.didExpire else { return true }
            state.cancelWorker = cancelWorker
            return false
        }
        if shouldCancel {
            cancelWorker()
        }
    }

    func expire() {
        let cancelWorker = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.didExpire else { return nil }
            state.didExpire = true
            defer { state.cancelWorker = nil }
            return state.cancelWorker
        }
        cancelWorker?()
    }
}
