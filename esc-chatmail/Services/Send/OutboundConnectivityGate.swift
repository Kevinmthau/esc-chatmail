import Foundation

/// Bounded wait for a usable network path, run by the send worker strictly
/// before its transmission barrier.
///
/// The send session does not wait for connectivity (a waited-out resource
/// timeout is ambiguous for a non-idempotent send), so without this wait a
/// brief outage — a Wi-Fi-to-cellular handoff, a gap between stations — burned
/// its few seconds of `-1009` retries and ended as "Not sent", needing Edit
/// and resend. Now a send that starts on a known-unsatisfied path waits for
/// the path to come back, up to `NetworkConfig.sendConnectivityWaitTimeout`.
///
/// Nothing here can transmit or retransmit: the wait runs before the barrier,
/// and a deadline failure is the same pre-transmission
/// `NSURLErrorNotConnectedToInternet` the send session would have raised, so
/// the request's `PreTransmissionFailureDisposition` decides the outcome (chat
/// replies retain as "Not sent"; compose and forward roll back to their
/// composer). Cancellation (account teardown, background expiry) throws
/// `CancellationError` at once and rolls back like any pre-barrier
/// cancellation. The wait is never repeated after the barrier.
enum OutboundConnectivityGate {
    static func waitForUsablePath(
        monitor: any OutboundNetworkPathMonitoring,
        clock: any SyncClock,
        timeout: TimeInterval = NetworkConfig.sendConnectivityWaitTimeout
    ) async throws {
        // A satisfied (or not yet reported) path is a no-op: no suspension and
        // no cancellation check of its own, so the send path behaves exactly
        // as it did without the gate (cancellation still reaches preflight and
        // the barrier's own `Task.checkCancellation()`).
        guard monitor.isPathKnownUnsatisfied else { return }

        Log.info("Send waiting for network path before transmission", category: .message)
        let pathReturned = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await monitor.waitUntilPathSatisfied()
                return true
            }
            group.addTask {
                try await clock.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return false
            }
            // Whichever finishes first decides; the loser is cancelled, and
            // both children unwind promptly on cancellation.
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        try Task.checkCancellation()

        guard pathReturned else {
            Log.warning(
                "Network path still unavailable after \(timeout)s; failing send before transmission",
                category: .message
            )
            throw URLError(.notConnectedToInternet)
        }
        Log.info("Network path returned; send continuing", category: .message)
    }
}
