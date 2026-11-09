import Foundation
import WebKit

/// What a click on a link in email text does when the text is shown outside a WebView, such as the
/// plain-text original-email reader, whose `NSDataDetector` links any scheme it finds (`smb:`,
/// `ssh:`, `file:`, another app's private scheme) and any host (`http://192.168.0.1`).
///
/// It is the full reader's rule: the same `FullInteractiveEmailWebView.navigationDecision` for a
/// `.linkActivated` click, so both readers refuse dangerous schemes, block private and reserved
/// hosts, and unwrap Amazon SES tracking links alike. The one difference is `.allow`, which in the
/// WebView lets a navigation proceed in place (an iOS `x-apple-data-detectors` link). Text has no
/// in-place navigation, so it is discarded.
///
/// `.openExternally` still goes through `ExternalURLOpener`, which applies the platform's own gate
/// (`canOpenURL` on iOS, `EmailLinkSchemePolicy.macOpenableSchemes` on the Mac).
enum EmailTextLinkPolicy {
    enum Action: Equatable {
        /// Hand the link, possibly an unwrapped tracking destination, to `ExternalURLOpener`.
        case openExternally(URL)
        /// Refuse a link to a private or reserved host, and log it.
        case blockedPrivateNetwork(URL)
        /// Refuse silently.
        case discard
    }

    static func action(for url: URL) -> Action {
        switch FullInteractiveEmailWebView.navigationDecision(navigationType: .linkActivated, url: url) {
        case .openExternally(let destination):
            return .openExternally(destination)
        case .blockedPrivateNetwork(let blocked):
            return .blockedPrivateNetwork(blocked)
        case .allow, .cancel:
            return .discard
        }
    }
}
