#if os(iOS)
import UIKit

/// The iOS sync-run lease. The Mac uses `InertSyncRunBackgroundTaskManager`.
typealias PlatformSyncRunBackgroundTaskManager = UIKitSyncRunBackgroundTaskManager

/// Asks UIKit for background time to finish a foreground-entry sync run
/// (`SyncRunBackgroundLease`). UIKit may expire the grant, and the lease then
/// cancels the run.
@MainActor
struct UIKitSyncRunBackgroundTaskManager: SyncRunBackgroundTaskManaging {
    func begin(expirationHandler: @escaping @MainActor @Sendable () -> Void) -> OutboundBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "Mailbox sync", expirationHandler: expirationHandler)
    }

    func end(_ identifier: OutboundBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
#endif
