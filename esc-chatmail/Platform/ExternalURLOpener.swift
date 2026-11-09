#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Hands a link to the system, which opens it in the default browser or the app that owns its
/// scheme (mail, phone, maps). Used where SwiftUI's `openURL` action is out of reach, such as a
/// `WKNavigationDelegate`.
@MainActor
enum ExternalURLOpener {
    static func open(_ url: URL) {
        #if canImport(UIKit)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
