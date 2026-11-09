#if os(macOS)
import Foundation

/// The Mac send lease. iOS uses `UIKitOutboundBackgroundTaskManager`.
typealias PlatformOutboundBackgroundTaskManager = ProcessActivityOutboundBackgroundTaskManager

/// Holds a `ProcessInfo` activity for each send in flight, so neither App Nap
/// nor idle system sleep stalls it.
///
/// macOS does not suspend an app that leaves the foreground, so unlike UIKit's
/// background time this lease never expires: `begin` drops the expiration
/// handler, and `backgroundTimeExpiredWithoutTeardown` never fires on the Mac.
/// Do not add a substitute that expires the lease or rolls a send back; a send
/// still running at quit is covered by `applicationShouldTerminate`'s bounded
/// wait (`AppLifecyclePolicy.terminationDecision`), and one cut short by a
/// forced quit by cold recovery, which converts its markers and never resends.
@MainActor
final class ProcessActivityOutboundBackgroundTaskManager: OutboundBackgroundTaskManaging {
    private var activities: [OutboundBackgroundTaskIdentifier: any NSObjectProtocol] = [:]
    private var lastRawValue = OutboundBackgroundTaskIdentifier.invalid.rawValue

    func begin(expirationHandler: @escaping @MainActor @Sendable () -> Void) -> OutboundBackgroundTaskIdentifier {
        lastRawValue += 1
        let identifier = OutboundBackgroundTaskIdentifier(rawValue: lastRawValue)
        // `.userInitiated` includes `.idleSystemSleepDisabled` and keeps App
        // Nap from throttling the process.
        activities[identifier] = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Send message"
        )
        return identifier
    }

    func end(_ identifier: OutboundBackgroundTaskIdentifier) {
        guard let activity = activities.removeValue(forKey: identifier) else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}
#endif
