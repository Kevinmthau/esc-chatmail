import Foundation

/// What sync knows of the network path: whether a run may start, and when a
/// path that was down comes back (`NetworkMonitorService`).
///
/// Injected into `SyncEngine` and `ForegroundSyncCoordinator` so a test can
/// drive a manual path (`NetworkMonitorService(manualStatus:)`) and never the
/// host machine's network.
protocol SyncNetworkPathMonitoring: AnyObject, Sendable {
    /// False only for a path known to be unsatisfied. A path not yet reported,
    /// one that requires a connection (an idle VPN On Demand tunnel) and an
    /// unknown status all read usable (`OutboundNetworkPathMonitor.isUsable`):
    /// the request itself brings such a path up, and the read session waits
    /// for connectivity on its own.
    var isPathUsable: Bool { get }

    /// A stream that yields once each time the path becomes usable after it
    /// was known to be unsatisfied. Each call is a subscriber of its own, so
    /// any number of callers may listen; ending the iteration (or cancelling
    /// the task that iterates) ends the subscription. Edges that arrive while
    /// the subscriber is busy are coalesced into one.
    func usablePathReturns() -> AsyncStream<Void>
}
