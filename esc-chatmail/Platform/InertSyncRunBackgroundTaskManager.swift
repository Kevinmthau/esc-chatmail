#if os(macOS)
import Foundation

/// The Mac sync-run lease, which holds nothing. iOS uses
/// `UIKitSyncRunBackgroundTaskManager`.
typealias PlatformSyncRunBackgroundTaskManager = InertSyncRunBackgroundTaskManager

/// Grants no background time and never expires, so `SyncRunBackgroundLease`
/// does nothing on the Mac.
///
/// macOS does not suspend an app that leaves the foreground, so a sync run
/// there needs no background time. Nor may it hold a `ProcessInfo` activity as
/// a send does (`ProcessActivityOutboundBackgroundTaskManager`):
/// `.userInitiated` disables idle system sleep, and the Mac's foreground sync
/// pauses for system sleep by decision (`AppLifecyclePolicy`,
/// `docs/mac-app-plan.md`). An activity held over every 60-second run would
/// keep an idle Mac awake (architecture review 2026-11, background-energy#2).
@MainActor
struct InertSyncRunBackgroundTaskManager: SyncRunBackgroundTaskManaging {
    func begin(expirationHandler: @escaping @MainActor @Sendable () -> Void) -> OutboundBackgroundTaskIdentifier {
        .invalid
    }

    func end(_ identifier: OutboundBackgroundTaskIdentifier) {}
}
#endif
