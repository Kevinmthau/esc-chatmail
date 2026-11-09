#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Hands a link to the system, which opens it in the default browser or the app that owns its
/// scheme (mail, phone, maps). Used by the full reader's `WKNavigationDelegate`, which SwiftUI's
/// `openURL` action cannot reach, and by the plain-text reader's link action
/// (`View.opensEmailTextLinksWithReaderPolicy()`), where SwiftUI's default action would skip the
/// email link rules.
///
/// Both platforms open `EmailLinkSchemePolicy.schemesOpenedOnEveryPlatform` (web, mail, phone,
/// Messages, FaceTime). The Mac opens nothing else, because `NSWorkspace.open` has no check of its
/// own. iOS opens any other scheme only when `canOpenURL` accepts it. That policy explains why the
/// query is not asked for the shared list, and how much more it accepts than the Mac's list.
@MainActor
enum ExternalURLOpener {
    static func open(_ url: URL) {
        open(url, on: .current, systemCanOpen: { systemCanOpen($0) }, systemOpen: { systemOpen($0) })
    }

    /// `open(_:)` with the platform, the system's `canOpenURL` answer and the system hand-off
    /// passed in, so the iOS-hosted tests run both platforms' rules without opening anything. Only
    /// `open(_:)` passes the real ones.
    static func open(
        _ url: URL,
        on platform: AppPlatform,
        systemCanOpen: (URL) -> Bool,
        systemOpen: (URL) -> Void
    ) {
        let opensOnEveryPlatform = EmailLinkSchemePolicy.opensOnEveryPlatform(url)
        switch platform {
        case .macOS:
            guard opensOnEveryPlatform else {
                Log.warning("Refused email link with a scheme the Mac does not open: \(Log.redact(url: url))", category: .ui)
                return
            }
        case .iOS:
            // The shared list goes straight to `UIApplication.open`, which needs no declared query
            // scheme. `canOpenURL` answered false for `mailto:`, `tel:` and `facetime:` on a
            // simulator where no Apple app claims them (`EmailLinkSchemePolicy` has the
            // measurement), so asking it first is expected to refuse an email address in a message
            // on a device without Apple Mail.
            guard opensOnEveryPlatform || systemCanOpen(url) else {
                return
            }
        }
        systemOpen(url)
    }

    /// iOS's query for a scheme outside the shared list. The Mac never asks it.
    private static func systemCanOpen(_ url: URL) -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.canOpenURL(url)
        #else
        false
        #endif
    }

    private static func systemOpen(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
