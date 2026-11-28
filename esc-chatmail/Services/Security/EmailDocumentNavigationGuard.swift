import Foundation

/// Keeps a navigation WebKit starts on its own, without a tap, from reaching a private host: a
/// `<meta http-equiv="refresh">` arrives as an `.other` navigation, which every email web view's
/// delegate allows for its own document load (architecture review 2026-11, `security-privacy#2`).
/// The rule list cannot cover it, because it never names the `document` type (a sender on a
/// `.local` domain must still be readable), and measured on the iOS 27.0 simulator with the list
/// attached and no sanitizer, such a refresh to `http://127.0.0.1` made its GET. The sanitizer
/// strips `meta`, `iframe` and `link` from every wrapped email, so this is the second line, for
/// markup that reaches a web view another way.
///
/// The document's own load is one: `loadHTMLString` navigates to the base URL it was given, the
/// sender's `https://<From domain>/`, which may itself be a private name (`nas.local`), so a
/// navigation to the base URL's own host is never refused here.
enum EmailDocumentNavigationGuard {
    /// Whether an `.other` or `.reload` navigation to `url` must be cancelled: an http(s) URL whose
    /// host `PrivateNetworkAddressDetector` refuses and that is not the document's own base host.
    static func refusesAutomaticNavigation(to url: URL?, documentBaseURL: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        if let baseHost = documentBaseURL?.host?.lowercased(),
           url.host?.lowercased() == baseHost {
            return false
        }
        return PrivateNetworkAddressDetector.isPrivateOrReserved(url)
    }
}
