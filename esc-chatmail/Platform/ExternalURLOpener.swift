#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Hands a link to the system, which opens it in the default browser or the app that owns its
/// scheme (mail, phone, maps). Used where SwiftUI's `openURL` action is out of reach, such as a
/// `WKNavigationDelegate`. On the Mac it is also the `openURL` action of views that show links from
/// email text (`View.opensEmailLinksThroughExternalURLOpener()`).
///
/// iOS opens only what `canOpenURL` accepts. The Mac has no such check on `NSWorkspace.open`, so it
/// opens only the schemes `MacExternalURLSchemePolicy` allows, which keeps a click in an email to
/// what iOS opens.
@MainActor
enum ExternalURLOpener {
    static func open(_ url: URL) {
        #if canImport(UIKit)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        #elseif canImport(AppKit)
        guard MacExternalURLSchemePolicy.allowsOpening(url) else {
            Log.warning("Refused email link with a scheme the Mac does not open: \(Log.redact(url: url))", category: .ui)
            return
        }
        NSWorkspace.shared.open(url)
        #endif
    }
}
