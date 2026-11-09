import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The system notifications shared code observes whose names differ between UIKit and AppKit.
enum PlatformNotificationNames {
    /// A window became the key window: `UIWindow.didBecomeKeyNotification` on iOS,
    /// `NSWindow.didBecomeKeyNotification` on the Mac.
    static var windowDidBecomeKey: Notification.Name {
        #if canImport(UIKit)
        UIWindow.didBecomeKeyNotification
        #else
        NSWindow.didBecomeKeyNotification
        #endif
    }

    /// The app became active: `UIApplication.didBecomeActiveNotification` on iOS,
    /// `NSApplication.didBecomeActiveNotification` on the Mac.
    static var applicationDidBecomeActive: Notification.Name {
        #if canImport(UIKit)
        UIApplication.didBecomeActiveNotification
        #else
        NSApplication.didBecomeActiveNotification
        #endif
    }
}
