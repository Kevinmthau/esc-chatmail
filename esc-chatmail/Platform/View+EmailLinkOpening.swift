import SwiftUI

extension View {
    /// On the Mac, sends a click on a link inside this view's email-derived text through
    /// `ExternalURLOpener`, so it gets the same `MacExternalURLSchemePolicy` allowlist as a link
    /// clicked in the full reader's WebView. Use it on every view that shows links built from email
    /// content (`.link` runs in an `AttributedString`).
    ///
    /// Without it, SwiftUI's default `openURL` hands the link to `NSWorkspace.open`, which launches
    /// whatever app registered the scheme, and `NSDataDetector` linkifies `ssh:`, `smb:`, `vnc:`,
    /// `file:` and any app's private scheme in plain text. Apply it to the email view only, never
    /// app-wide: the app's own links, such as the Mac's `x-apple.systempreferences:` Contacts
    /// settings link (`PlatformSettingsURL`), would be refused.
    ///
    /// iOS keeps SwiftUI's default action, so nothing about iOS changes.
    func opensEmailLinksThroughExternalURLOpener() -> some View {
        #if os(macOS)
        environment(\.openURL, OpenURLAction { url in
            ExternalURLOpener.open(url)
            return .handled
        })
        #else
        self
        #endif
    }
}
