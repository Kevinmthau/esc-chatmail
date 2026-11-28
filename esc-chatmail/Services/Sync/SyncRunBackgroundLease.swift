import Foundation

/// Begins and ends the platform's background time for one foreground-entry
/// sync run: `UIKitSyncRunBackgroundTaskManager` on iOS,
/// `InertSyncRunBackgroundTaskManager` on the Mac
/// (`PlatformSyncRunBackgroundTaskManager` names the current one).
///
/// A protocol of its own, not `OutboundBackgroundTaskManaging`, so that the
/// Mac's send manager can never be handed to a sync run: it holds a
/// `.userInitiated` activity, which disables idle system sleep, and the Mac's
/// foreground sync pauses for system sleep by decision (`AppLifecyclePolicy`).
/// The identifier is the platform's background-task identifier the send lease
/// also uses.
@MainActor
protocol SyncRunBackgroundTaskManaging {
    func begin(expirationHandler: @escaping @MainActor @Sendable () -> Void) -> OutboundBackgroundTaskIdentifier
    func end(_ identifier: OutboundBackgroundTaskIdentifier)
}

/// Keeps one foreground-entry sync run (`SyncEngine.triggerIncrementalSyncIfPossible`)
/// eligible to finish when the iOS app goes to the background, from the turn
/// the run is admitted until its whole chain has ended: the run's `endRun` and
/// the store maintenance asked for after it.
///
/// Before it, going to the background stopped only the foreground
/// coordinator's timers. A run still in flight froze at suspension while it
/// held the exclusive boundary, and a background task woken beside it found
/// the boundary held and synced nothing (architecture review 2026-11,
/// startup-lifecycle#3, background-energy#2). Now such a run either finishes
/// within the grant or is cancelled at its expiration.
///
/// The expiration is UIKit's, on the main thread. It cancels the run
/// synchronously (`onExpiration`) and then ends the lease at once. Nothing may
/// be awaited there: a background task left unended past its grant is a
/// watchdog kill, so the run's rollback finishes unwinding when the process
/// next runs. Cancelling a sync run is always safe: it throws
/// `CancellationError`, rolls back, and records no per-message verdict.
///
/// The shape is `OutboundSendBackgroundLease`'s. A grant UIKit refuses
/// (`.invalid`) cancels nothing, so the run goes on as it did before the
/// lease; a background wake that meets it now schedules its catch-up
/// (`BackgroundSyncManager.shouldScheduleRetryWhenBlocked`). On the Mac the
/// manager grants nothing and never expires.
///
/// `begin` is apart from `init` so the chain task that ends the lease can
/// exist before the expiration handler that cancels it.
@MainActor
final class SyncRunBackgroundLease {
    private let manager: any SyncRunBackgroundTaskManaging
    private var identifier = OutboundBackgroundTaskIdentifier.invalid
    private var hasBegun = false
    private var hasEnded = false

    init(manager: any SyncRunBackgroundTaskManaging) {
        self.manager = manager
    }

    /// Begins the lease. Called once; a second call, or a call after `end()`,
    /// does nothing.
    func begin(onExpiration: @escaping @MainActor @Sendable () -> Void) {
        guard !hasBegun, !hasEnded else { return }
        hasBegun = true
        let identifier = manager.begin { [weak self] in
            guard let self, !self.hasEnded else { return }
            onExpiration()
            // Not after the run's rollback: UIKit's time is returned now.
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
