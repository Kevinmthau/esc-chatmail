import Foundation

/// Which schemes the Mac hands to the system when a link in an email is clicked
/// (`ExternalURLOpener`).
///
/// On iOS, `ExternalURLOpener` opens a link only when `UIApplication.canOpenURL` says it can, and
/// the app declares no `LSApplicationQueriesSchemes`, so in practice only the system's own schemes
/// (web, mail, phone, Messages, FaceTime) get through: a link to another app's custom scheme is
/// refused. `NSWorkspace.open` has no such check and launches whichever app registered a scheme
/// (`ssh:`, `smb:`, `vnc:`, an installed app's private scheme), so on the Mac a link from untrusted
/// email content would reach any of them. The Mac checks this allowlist instead, which keeps a
/// click to what iOS opens. Widen it deliberately, one scheme at a time.
///
/// iOS does not consult it; its `canOpenURL` gate is unchanged. The policy has no platform code so
/// the iOS-hosted unit tests can pin it.
enum MacExternalURLSchemePolicy {
    /// The lowercased schemes a clicked email link may open on the Mac.
    static let allowedSchemes: Set<String> = [
        "http",
        "https",
        "mailto",
        "tel",
        "sms",
        "facetime",
        "facetime-audio"
    ]

    /// Whether `url`'s scheme, compared case-insensitively, is in `allowedSchemes`. A URL with no
    /// scheme is refused.
    static func allowsOpening(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return allowedSchemes.contains(scheme)
    }
}
