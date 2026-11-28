import Foundation
#if os(iOS)
import UIKit
#endif
@testable import esc_chatmail

/// Records the grants a `SyncRunBackgroundLease` asks for and lets a test
/// deliver the expiration UIKit would.
@MainActor
final class SyncRunBackgroundTaskManagerSpy: SyncRunBackgroundTaskManaging {
    let grantedIdentifier = OutboundBackgroundTaskIdentifier(rawValue: 42)
    /// What `begin` answers; `.invalid` is a grant the platform refused.
    var identifierToGrant: OutboundBackgroundTaskIdentifier?
    /// Expires the grant inside `begin`, before it returns.
    var expiresDuringBegin = false
    var onEnd: () -> Void = {}
    private(set) var beginCount = 0
    private(set) var endedIdentifiers: [OutboundBackgroundTaskIdentifier] = []
    private var expirationHandler: (@MainActor @Sendable () -> Void)?

    var endCount: Int { endedIdentifiers.count }

    func begin(expirationHandler: @escaping @MainActor @Sendable () -> Void) -> OutboundBackgroundTaskIdentifier {
        beginCount += 1
        self.expirationHandler = expirationHandler
        if expiresDuringBegin {
            expirationHandler()
        }
        return identifierToGrant ?? grantedIdentifier
    }

    func end(_ identifier: OutboundBackgroundTaskIdentifier) {
        endedIdentifiers.append(identifier)
        onEnd()
    }

    /// Delivers the grant's expiration, synchronously, as UIKit does on the
    /// main thread.
    func expire() {
        expirationHandler?()
    }
}
