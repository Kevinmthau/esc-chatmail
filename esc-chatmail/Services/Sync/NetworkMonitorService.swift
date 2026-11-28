import Foundation
import Network

/// Sync's view of the network path (`SyncNetworkPathMonitoring`): the
/// preflight `SyncEngine` asks before a run, and the edge that tells
/// `ForegroundSyncCoordinator` the path has come back.
///
/// The status is kept under a lock and written synchronously in
/// `pathUpdateHandler`. It was an actor flag written through a new `Task` for
/// each path update, and those tasks run in no guaranteed order, so a
/// reordering could leave it reading "no network" on a link that was up until
/// the next update came, skipping every sync, pull-to-refresh included
/// (architecture review 2026-11, background-energy#5). And it counted only
/// `.satisfied` as online, so an idle VPN On Demand tunnel
/// (`.requiresConnection`) held every sync until something else brought the
/// tunnel up.
///
/// Now only a path known to be unsatisfied refuses a run: the status goes
/// through `OutboundNetworkPathMonitor.isUsable`, and a path not reported yet
/// is usable. That skip is kept on purpose. The read session waits for
/// connectivity itself (`waitsForConnectivity`, a 60 s resource timeout and
/// retries), so a run started offline would hold the exclusive run boundary
/// for minutes, with pending actions, store maintenance and background tasks
/// parked behind it.
///
/// Its own monitor, apart from the send gate's (`OutboundNetworkPathMonitor`,
/// whose manual satisfied instance the hosted send suites rely on) and from
/// `AppNetworkMonitor`, whose one `onConnectivityChange` slot is the pending
/// action queue's. Nothing may `cancel()` it from outside: an `NWPathMonitor`
/// cannot be started again, so a shared one cancelled would leave sync blind
/// for the rest of the process. Only `deinit` cancels it, for an instance
/// nothing holds any more; `shared` is never released.
///
/// `@unchecked Sendable`: `lock` guards `status` and `subscribers`.
/// `NWPathMonitor` delivers updates on `queue`, and subscribers are yielded to
/// outside the lock.
final class NetworkMonitorService: SyncNetworkPathMonitoring, @unchecked Sendable {
    /// The one `SyncEngine.shared` and `ForegroundSyncCoordinator.shared` use.
    ///
    /// Hosted unit tests get a manual monitor that has had no update, which
    /// reads usable and never yields an edge: a test's sync must not depend on
    /// the host machine's network, nor be started by it. Suites that exercise
    /// the path inject their own.
    static let shared: NetworkMonitorService = RuntimeEnvironment.isRunningUnitTests
        ? NetworkMonitorService(manualStatus: nil)
        : NetworkMonitorService()

    private let monitor: NWPathMonitor?
    private let lock = NSLock()
    /// nil until the first path update.
    private var status: NWPath.Status?
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Starts a system `NWPathMonitor`.
    init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathDidChange(to: path.status, isExpensive: path.isExpensive)
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    /// Testable initializer: no system monitor; `pathDidChange(to:)` drives
    /// the status. nil is a path not reported yet.
    init(manualStatus: NWPath.Status?) {
        self.monitor = nil
        self.status = manualStatus
    }

    deinit {
        monitor?.cancel()
    }

    var isPathUsable: Bool {
        lock.withLock { Self.isUsable(status) }
    }

    /// A status not reported yet is usable, as `OutboundNetworkPathMonitor`
    /// reads it.
    static func isUsable(_ status: NWPath.Status?) -> Bool {
        guard let status else { return true }
        return OutboundNetworkPathMonitor.isUsable(status)
    }

    /// Records a path update, in the handler's own call, and yields to every
    /// subscriber when it turns a known-unsatisfied path usable.
    func pathDidChange(to newStatus: NWPath.Status, isExpensive: Bool = false) {
        let edgeSubscribers: [AsyncStream<Void>.Continuation] = lock.withLock {
            let wasUsable = Self.isUsable(status)
            status = newStatus
            guard !wasUsable, Self.isUsable(newStatus) else { return [] }
            return Array(subscribers.values)
        }
        edgeSubscribers.forEach { $0.yield() }
        Log.debug("Network status: \(newStatus), expensive: \(isExpensive)", category: .general)
    }

    func usablePathReturns() -> AsyncStream<Void> {
        let subscriberID = UUID()
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(subscriberID)
        }
        lock.withLock { subscribers[subscriberID] = continuation }
        return stream
    }

    /// How many subscriptions are live. Read by tests, to see an ended one
    /// dropped.
    var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    private func removeSubscriber(_ subscriberID: UUID) {
        lock.withLock { _ = subscribers.removeValue(forKey: subscriberID) }
    }
}
