#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Hands a link to the system, which opens it in the default browser or the app that owns its
/// scheme (mail, phone, maps). Used where SwiftUI's default `openURL` action would skip the email
/// link rules: the full reader's `WKNavigationDelegate`, and the plain-text reader's link action
/// (`View.opensEmailTextLinksWithReaderPolicy()`).
///
/// iOS opens only what `canOpenURL` accepts. The Mac has no such check on `NSWorkspace.open`, so it
/// opens only `EmailLinkSchemePolicy.macOpenableSchemes` (that policy explains how the two sets
/// differ).
@MainActor
enum ExternalURLOpener {
    static func open(_ url: URL) {
        open(url, on: .current, systemOpen: { systemOpen($0) })
    }

    /// `open(_:)` with the platform and the system hand-off passed in, so the iOS-hosted tests run
    /// the Mac's rule without opening anything. Only `open(_:)` passes the real ones.
    static func open(_ url: URL, on platform: AppPlatform, systemOpen: (URL) -> Void) {
        if platform == .macOS, !EmailLinkSchemePolicy.allowsOpeningOnMac(url) {
            Log.warning("Refused email link with a scheme the Mac does not open: \(Log.redact(url: url))", category: .ui)
            return
        }
        systemOpen(url)
    }

    /// iOS keeps its own gate here: `canOpenURL` admits the system's schemes plus Info.plist's
    /// `LSApplicationQueriesSchemes`.
    private static func systemOpen(_ url: URL) {
        #if canImport(UIKit)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
