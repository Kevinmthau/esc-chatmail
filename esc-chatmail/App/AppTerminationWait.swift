import Foundation

/// Bounds how long quitting waits for sends in flight and for reply-draft
/// writes. The Mac's `applicationShouldTerminate` answers `.terminateLater`
/// while either is outstanding (`AppLifecyclePolicy.terminationDecision`) and
/// replies once this returns.
///
/// It only waits: no send is cancelled, rolled back or retried, so the send
/// outcome matrix is untouched, and no draft is written here. A send still
/// running when the wait times out dies with the process, and cold recovery
/// (`reconcileAbandonedOptimisticSendMutations`) converts its markers at the
/// next launch without resending. A draft write still waiting for the cleanup
/// gate then dies too, losing what was typed since the composer's last save,
/// as every quit did before drafts were waited for.
///
/// Sends and drafts share one deadline and are waited for until both are idle
/// at once, because each can start the other's work: a send's release
/// schedules a draft save (`ChatViewModel.sendReply`'s deferred save,
/// `saveComposerLeftWhileSending`), and a failed send's reply is merged into
/// the stored draft (`handOffUnsentReply`).
enum AppTerminationWait {
    enum Outcome: Equatable, Sendable {
        /// Nothing was outstanding, or the last of it finished in time.
        case finished
        /// Something was still outstanding at the deadline.
        case timedOut(sendsOutstanding: Bool, draftWritesOutstanding: Bool)
    }

    private enum FirstToFinish: Sendable {
        case work
        case deadline
    }

    @MainActor
    static func waitForOutstandingWork(
        sends registry: OutboundTaskRegistry,
        draftWrites tracker: ReplyDraftWriteTracker,
        timeout: TimeInterval,
        clock: any SyncClock
    ) async -> Outcome {
        guard registry.hasOutstandingSends || tracker.hasOutstandingWrites else { return .finished }

        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let first = await withTaskGroup(of: FirstToFinish.self) { group in
            group.addTask { @MainActor in
                // Each wait returns at once when its side is idle, and early
                // when this child is cancelled.
                while !Task.isCancelled,
                      registry.hasOutstandingSends || tracker.hasOutstandingWrites {
                    await registry.waitUntilOutstandingSendsFinish()
                    await tracker.waitUntilIdle()
                }
                return .work
            }
            group.addTask {
                // Cancelled only once the other child has already won.
                try? await clock.sleep(nanoseconds: timeoutNanoseconds)
                return .deadline
            }
            let first = await group.next() ?? .deadline
            // Ends the losing child: a cancelled waiter returns without
            // touching any send or draft, and a cancelled sleep throws.
            group.cancelAll()
            return first
        }

        switch first {
        case .work:
            return .finished
        case .deadline:
            let sendsOutstanding = registry.hasOutstandingSends
            let draftWritesOutstanding = tracker.hasOutstandingWrites
            // The last of it may have finished as the deadline passed.
            guard sendsOutstanding || draftWritesOutstanding else { return .finished }
            return .timedOut(
                sendsOutstanding: sendsOutstanding,
                draftWritesOutstanding: draftWritesOutstanding
            )
        }
    }
}
