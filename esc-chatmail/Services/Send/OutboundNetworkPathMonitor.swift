import Foundation
import Network

/// `NWPathMonitor`-backed `OutboundNetworkPathMonitoring`.
///
/// Separate from `AppNetworkMonitor` (single `onConnectivityChange` callback,
/// owned by `PendingActionsManager`): any number of send workers may wait here
/// at once, each with its own cancellation.
///
/// `@unchecked Sendable`: `lock` guards `isSatisfied` and `waiters`;
/// `NWPathMonitor` delivers updates on `queue`, and waiters are resumed outside
/// the lock.
final class OutboundNetworkPathMonitor: OutboundNetworkPathMonitoring, @unchecked Sendable {
    /// Started when first touched; `OutboundMessageCoordinator` resolves it in
    /// its initializer so the first path update has normally arrived before
    /// the first send asks.
    ///
    /// Hosted unit tests get a manual monitor that reports a satisfied path:
    /// send suites drive `StubURLProtocol` and ran without network before this
    /// wait existed, and must not start waiting on the host machine's real
    /// connectivity. Suites that exercise the wait inject their own monitor.
    static let shared: OutboundNetworkPathMonitor = RuntimeEnvironment.isRunningUnitTests
        ? OutboundNetworkPathMonitor(manualPathSatisfied: true)
        : OutboundNetworkPathMonitor()

    private let monitor: NWPathMonitor?
    private let lock = NSLock()
    /// nil until the first path update.
    private var isSatisfied: Bool?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Starts a system `NWPathMonitor`.
    init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathDidChange(isSatisfied: path.status == .satisfied)
        }
        monitor.start(
            queue: DispatchQueue(label: "com.esc-chatmail.OutboundNetworkPathMonitor", qos: .userInitiated)
        )
    }

    /// Testable initializer: no system monitor; `pathDidChange(isSatisfied:)`
    /// drives the state.
    init(manualPathSatisfied: Bool?) {
        self.monitor = nil
        self.isSatisfied = manualPathSatisfied
    }

    deinit {
        monitor?.cancel()
    }

    var isPathKnownUnsatisfied: Bool {
        lock.withLock { isSatisfied == false }
    }

    /// Sends currently suspended in `waitUntilPathSatisfied`. Lets tests
    /// observe that a send is parked on the path rather than merely slow.
    var suspendedWaiterCount: Int {
        lock.withLock { waiters.count }
    }

    func pathDidChange(isSatisfied satisfied: Bool) {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            isSatisfied = satisfied
            guard satisfied else { return [] }
            let released = Array(waiters.values)
            waiters.removeAll()
            return released
        }
        released.forEach { $0.resume() }
    }

    func waitUntilPathSatisfied() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Decided under the lock so a path update cannot slip between
                // the check and the registration. `Task.isCancelled` is read
                // here too: the cancellation handler can run before this body
                // registers anything, and would then find nothing to resume.
                let immediate = lock.withLock { () -> Result<Void, Error>? in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if isSatisfied != false {
                        return .success(())
                    }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
