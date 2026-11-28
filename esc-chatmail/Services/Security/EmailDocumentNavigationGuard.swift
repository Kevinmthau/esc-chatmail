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
/// The document's own load is one of these navigations too: `loadHTMLString` navigates to the base
/// URL it was given, which is never a private host (`EmailSenderBaseURLResolver` gives none for a
/// domain the detector refuses, and the document then loads at `about:blank`), so the guard needs
/// no exception for it. It had one, for the base URL's own host, and a sender whose From domain was
/// a private host used it to send a refresh there.
enum EmailDocumentNavigationGuard {
    /// Whether an `.other` or `.reload` navigation to `url` must be cancelled: an http(s) URL whose
    /// host `PrivateNetworkAddressDetector` refuses.
    static func refusesAutomaticNavigation(to url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return PrivateNetworkAddressDetector.isPrivateOrReserved(url)
    }
}
