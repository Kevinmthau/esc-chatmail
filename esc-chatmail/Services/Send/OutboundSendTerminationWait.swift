import Foundation

/// Bounds how long quitting waits for sends in flight. The Mac's
/// `applicationShouldTerminate` answers `.terminateLater` while a send is
/// outstanding (`AppLifecyclePolicy.terminationDecision`) and replies once
/// this returns.
///
/// It only waits: no send is cancelled, rolled back or retried, so the send
/// outcome matrix is untouched. A send still running when the wait times out
/// dies with the process, and cold recovery
/// (`reconcileAbandonedOptimisticSendMutations`) converts its markers at the
/// next launch without resending.
enum OutboundSendTerminationWait {
    enum Outcome: Equatable, Sendable {
        /// No send was outstanding, or the last one finished in time.
        case sendsFinished
        /// At least one send was still outstanding at the deadline.
        case timedOut
    }

    @MainActor
    static func waitForOutstandingSends(
        in registry: OutboundTaskRegistry,
        timeout: TimeInterval,
        clock: any SyncClock
    ) async -> Outcome {
        guard registry.hasOutstandingSends else { return .sendsFinished }

        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask { @MainActor in
                await registry.waitUntilOutstandingSendsFinish()
                return .sendsFinished
            }
            group.addTask {
                // Cancelled only once the other child has already won.
                try? await clock.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }
            let outcome = await group.next() ?? .timedOut
            // Ends the losing child: a cancelled waiter returns without
            // touching any send, and a cancelled sleep throws.
            group.cancelAll()
            return outcome
        }
    }
}
