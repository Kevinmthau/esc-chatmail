import SwiftUI

extension View {
    /// Gives links in this view's email text the full reader's link rules (`EmailTextLinkPolicy`),
    /// on both platforms, instead of SwiftUI's default `openURL`, which opens any scheme and any
    /// host: `UIApplication.open` on iOS, and on the Mac `NSWorkspace.open`, which launches whatever
    /// app registered the scheme.
    ///
    /// Apply it to views that show email-derived links (`.link` runs in an `AttributedString`),
    /// never app-wide: the app's own links, such as the Mac's `x-apple.systempreferences:` Contacts
    /// settings link (`PlatformSettingsURL`), would be refused.
    func opensEmailTextLinksWithReaderPolicy() -> some View {
        environment(\.openURL, OpenURLAction { url in
            switch EmailTextLinkPolicy.action(for: url) {
            case .openExternally(let destination):
                ExternalURLOpener.open(destination)
                return .handled
            case .blockedPrivateNetwork(let blocked):
                FullInteractiveEmailWebView.logBlockedPrivateNetworkLink(blocked)
                return .discarded
            case .discard:
                return .discarded
            }
        })
    }
}
