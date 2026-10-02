import Foundation

/// The connectivity source a send worker consults before it queues for its
/// conversation turn (`OutboundConnectivityGate`). Production uses
/// `OutboundNetworkPathMonitor`; tests inject a fake so no test waits on the
/// host's real network.
protocol OutboundNetworkPathMonitoring: AnyObject, Sendable {
    /// True only once the monitor has observed an unsatisfied path. A path
    /// not yet reported is not "known unsatisfied": the send proceeds, and the
    /// fail-fast send session still turns a genuinely offline attempt into a
    /// pre-transmission `NSURLErrorNotConnectedToInternet`.
    var isPathKnownUnsatisfied: Bool { get }

    /// Suspends until the path reports satisfied, and returns at once when it
    /// is not known to be unsatisfied. Throws `CancellationError` as soon as
    /// the calling task is cancelled, so account teardown and background
    /// expiry never wait out an outage.
    func waitUntilPathSatisfied() async throws
}
