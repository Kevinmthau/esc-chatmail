import Foundation
import Network

/// A TCP listener on the loopback interface that records the first line of every request made to
/// it, so a test can see whether a web view connected to a loopback host at all, and for which
/// resource. It answers nothing: what is pinned is that a connection was made, not what it got.
///
/// `NWListener` delivers on a queue of its own, so the recorded lines are kept under a lock.
final class LoopbackConnectionRecorder: @unchecked Sendable {
    /// `@unchecked Sendable`: `lock` guards `connections` and `requestLines`; `listener` and the
    /// queue are set once in `init` and only read after.
    private let lock = NSLock()
    private var connections: Int = 0
    private var requestLines: [String] = []
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackConnectionRecorder")

    /// The port the listener was given, valid once `start()` has returned.
    private(set) var port: UInt16 = 0

    init(ipv6: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: ipv6 ? .ipv6(.loopback) : .ipv4(.loopback),
            port: .any
        )
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and waits (bounded) until the listener has its port.
    func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success,
              let port = listener.port?.rawValue else {
            throw NSError(domain: "LoopbackConnectionRecorder", code: 1)
        }
        self.port = port
    }

    func stop() {
        listener.cancel()
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    var recordedRequestLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLines
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections += 1
        lock.unlock()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let self, let data else { return }
            let text = String(decoding: data, as: UTF8.self)
            let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? "<non-HTTP \(data.count) bytes>"
            self.lock.lock()
            self.requestLines.append(firstLine)
            self.lock.unlock()
        }
    }
}
