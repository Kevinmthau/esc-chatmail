import Foundation

/// Begins and ends the platform's background-time lease for one send:
/// `UIKitOutboundBackgroundTaskManager` on iOS,
/// `ProcessActivityOutboundBackgroundTaskManager` on the Mac
/// (`PlatformOutboundBackgroundTaskManager` names the current one).
@MainActor
protocol OutboundBackgroundTaskManaging {
    func begin(expirationHandler: @escaping @MainActor @Sendable () -> Void) -> OutboundBackgroundTaskIdentifier
    func end(_ identifier: OutboundBackgroundTaskIdentifier)
}

/// Keeps send preflight, transmission, and local commit eligible to finish when
/// the app backgrounds. UIKit controls the time budget; this is not a retry job.
/// On the Mac the lease is a `ProcessInfo` activity that never expires, so
/// `onExpiration` never runs there.
@MainActor
final class OutboundSendBackgroundLease {
    private let manager: any OutboundBackgroundTaskManaging
    private var identifier = OutboundBackgroundTaskIdentifier.invalid
    private var hasEnded = false

    init(
        manager: any OutboundBackgroundTaskManaging,
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) {
        self.manager = manager
        let identifier = manager.begin { [weak self] in
            guard let self, !self.hasEnded else { return }
            onExpiration()
            // Do not wait for async cancellation cleanup to return UIKit's time.
            // An admitted send already has a durable ambiguity marker if the
            // process is suspended before its worker can record the outcome.
            self.end()
        }
        if hasEnded {
            // Also tolerate a manager expiring synchronously during begin.
            if identifier != .invalid { manager.end(identifier) }
        } else {
            self.identifier = identifier
        }
    }

    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        guard identifier != .invalid else { return }
        manager.end(identifier)
        identifier = .invalid
    }
}
