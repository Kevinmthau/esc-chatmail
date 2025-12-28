import Foundation
import Network

// MARK: - Network Monitor Protocol

protocol NetworkMonitorProtocol: AnyObject {
    var isConnected: Bool { get }
    var onConnectivityChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - Network Monitor

/// Monitors network connectivity using NWPathMonitor
/// Provides a simple interface to check connectivity and receive updates
final class AppNetworkMonitor: NetworkMonitorProtocol {
    static let shared = AppNetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var _isConnected: Bool = true
    private let lock = NSLock()

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    var onConnectivityChange: ((Bool) -> Void)?

    private init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.esc-chatmail.NetworkMonitor", qos: .utility)
    }

    /// Testable initializer
    init(monitor: NWPathMonitor, queue: DispatchQueue) {
        self.monitor = monitor
        self.queue = queue
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let isConnected = path.status == .satisfied

            self.lock.lock()
            let wasConnected = self._isConnected
            self._isConnected = isConnected
            self.lock.unlock()

            // Only notify if connectivity actually changed
            if wasConnected != isConnected {
                Log.info("Network connectivity changed: \(isConnected ? "connected" : "disconnected")", category: .sync)
                self.onConnectivityChange?(isConnected)
            }
        }

        monitor.start(queue: queue)
        Log.debug("Network monitor started", category: .sync)
    }

    func stop() {
        monitor.cancel()
        Log.debug("Network monitor stopped", category: .sync)
    }
}

// MARK: - Mock Network Monitor for Testing

#if DEBUG
final class MockNetworkMonitor: NetworkMonitorProtocol {
    var isConnected: Bool = true
    var onConnectivityChange: ((Bool) -> Void)?

    func start() {}
    func stop() {}

    func simulateConnectivityChange(_ connected: Bool) {
        isConnected = connected
        onConnectivityChange?(connected)
    }
}
#endif
