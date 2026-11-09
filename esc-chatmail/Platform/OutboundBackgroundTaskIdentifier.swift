#if os(iOS)
import UIKit

/// Names one send's background-time lease: UIKit's own identifier on iOS, so
/// nothing about the iOS lease changes.
typealias OutboundBackgroundTaskIdentifier = UIBackgroundTaskIdentifier
#elseif os(macOS)
import Foundation

/// Names one send's background-time lease on the Mac, where it stands for a
/// `ProcessInfo` activity (`ProcessActivityOutboundBackgroundTaskManager`).
/// Shaped like `UIBackgroundTaskIdentifier`, whose `.invalid` is also 0, so
/// `OutboundSendBackgroundLease` reads the same on both platforms.
struct OutboundBackgroundTaskIdentifier: RawRepresentable, Hashable, Sendable {
    static let invalid = OutboundBackgroundTaskIdentifier(rawValue: 0)

    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}
#endif
