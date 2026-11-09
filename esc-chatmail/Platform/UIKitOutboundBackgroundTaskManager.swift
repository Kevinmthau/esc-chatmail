#if os(iOS)
import UIKit

/// The iOS send lease. The Mac uses `ProcessActivityOutboundBackgroundTaskManager`.
typealias PlatformOutboundBackgroundTaskManager = UIKitOutboundBackgroundTaskManager

/// Asks UIKit for background time to finish a send. UIKit may expire the
/// grant, which is what `ComposeSendCancellationRelay.expireBackgroundTime()`
/// and `backgroundTimeExpiredWithoutTeardown` exist for.
@MainActor
struct UIKitOutboundBackgroundTaskManager: OutboundBackgroundTaskManaging {
    func begin(expirationHandler: @escaping @MainActor @Sendable () -> Void) -> OutboundBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "Send message", expirationHandler: expirationHandler)
    }

    func end(_ identifier: OutboundBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
#endif
