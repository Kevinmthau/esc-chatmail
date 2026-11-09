import Foundation

/// Which URL schemes a link from email content may reach, as one definition shared by the two
/// places that decide it, so their lists cannot drift apart unnoticed:
///
/// - `macOpenableSchemes`: what `ExternalURLOpener` hands to `NSWorkspace.open` on the Mac when a
///   link in an email is clicked.
/// - `amazonSESDestinationSchemes`: what an Amazon SES tracking link may unwrap to
///   (`FullInteractiveEmailWebView.navigationDecision`), on both platforms.
///
/// On iOS, `ExternalURLOpener` opens a link only when `UIApplication.canOpenURL` says it can. That
/// admits the system's own schemes (web, mail, phone, Messages, FaceTime) plus the two that
/// Info.plist lists under `LSApplicationQueriesSchemes`: `google` and the app's own Google OAuth
/// redirect scheme (`GOOGLE_REDIRECT_URI`). Any other app's custom scheme is refused.
/// `NSWorkspace.open` has no such check and launches whichever app registered a scheme (`ssh:`,
/// `smb:`, `vnc:`, an installed app's private scheme), so on the Mac a link from untrusted email
/// content would reach any of them. The Mac checks `macOpenableSchemes` instead. That is iOS's
/// system set without the two queried schemes: the Mac has no Google app, and an email link must
/// never feed the app's own sign-in redirect. Widen it deliberately, one scheme at a time.
///
/// The policy has no platform code, so the iOS-hosted unit tests pin it.
enum EmailLinkSchemePolicy {
    /// The lowercased schemes a clicked email link may open on the Mac.
    static let macOpenableSchemes: Set<String> = [
        "http",
        "https",
        "mailto",
        "tel",
        "sms",
        "facetime",
        "facetime-audio"
    ]

    /// The lowercased schemes an Amazon SES tracking link may unwrap to: web, mail and phone only,
    /// narrower than `macOpenableSchemes` (an SES-wrapped `facetime:` link is cancelled, pinned by
    /// `testAmazonSESTrackingLinkToDisallowedSchemeIsCancelled`). It must stay a subset of
    /// `macOpenableSchemes`, or the Mac would refuse a destination the unwrap had just allowed.
    static let amazonSESDestinationSchemes: Set<String> = [
        "http",
        "https",
        "mailto",
        "tel"
    ]

    /// Whether `url`'s scheme, compared case-insensitively, is in `macOpenableSchemes`. A URL with
    /// no scheme is refused.
    static func allowsOpeningOnMac(_ url: URL) -> Bool {
        schemeIsAllowed(url, in: macOpenableSchemes)
    }

    /// Whether `url`'s scheme, compared case-insensitively, is in `amazonSESDestinationSchemes`. A
    /// URL with no scheme is refused.
    static func allowsAmazonSESDestination(_ url: URL) -> Bool {
        schemeIsAllowed(url, in: amazonSESDestinationSchemes)
    }

    private static func schemeIsAllowed(_ url: URL, in allowedSchemes: Set<String>) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return allowedSchemes.contains(scheme)
    }
}
