import Foundation

/// Which URL schemes a link from email content may reach, as one definition shared by the places
/// that decide it, so their lists cannot drift apart unnoticed:
///
/// - `schemesOpenedOnEveryPlatform`: what `ExternalURLOpener` hands to the system on both
///   platforms when a link in an email is clicked: web, mail, phone, Messages and FaceTime.
/// - `amazonSESDestinationSchemes`: what an Amazon SES tracking link may unwrap to
///   (`FullInteractiveEmailWebView.navigationDecision`), on both platforms.
///
/// The Mac opens nothing outside `schemesOpenedOnEveryPlatform`. `NSWorkspace.open` launches
/// whichever app registered a scheme (`ssh:`, `smb:`, `vnc:`, an installed app's private scheme),
/// so a link from untrusted email content would otherwise reach any of them. Widen the list
/// deliberately, one scheme at a time.
///
/// iOS opens that list without asking `UIApplication.canOpenURL`, and any other scheme only when
/// `canOpenURL` accepts it. The query is not asked for the list because it is the wrong gate for
/// it. Measured on the iOS 27.0 simulator, which ships no Mail, Phone or FaceTime, with this app's
/// Info.plist: `canOpenURL` refused `mailto:`, `tel:`, `facetime:` and `facetime-audio:` as schemes
/// the app is not allowed to query, and accepted `sms:`, whose app (Messages) that simulator does
/// have. So an undeclared scheme passed only while an Apple app on the device claimed it. From
/// that, gating on the query is expected to refuse an email address in a message on a device
/// without Apple Mail. That step is an inference, not a measurement: no simulator has a
/// third-party default mail app for `UIApplication.open` to reach.
///
/// For a scheme outside the list, iOS's `canOpenURL` is wider than the Mac's rule, not equal to
/// it. On the same simulator it accepted, undeclared, `maps:`, `shortcuts:`, `smb:`,
/// `x-apple-reminderkit:` and `app-settings:`, and it also admits the two schemes Info.plist does
/// list under `LSApplicationQueriesSchemes`: `google` and the app's own Google OAuth redirect
/// scheme (`GOOGLE_REDIRECT_URI`). A third-party app's undeclared scheme (`zoommtg:`) is refused.
/// The Mac refuses all of those. That includes the two queried schemes: the Mac has no Google app,
/// and an email link should not feed the app's own sign-in redirect. Only the Mac enforces that;
/// on iOS the redirect scheme still passes `canOpenURL`.
///
/// The policy has no platform code, so the iOS-hosted unit tests pin it.
enum EmailLinkSchemePolicy {
    /// The lowercased schemes a clicked email link opens on both platforms. On the Mac they are the
    /// only ones.
    static let schemesOpenedOnEveryPlatform: Set<String> = [
        "http",
        "https",
        "mailto",
        "tel",
        "sms",
        "facetime",
        "facetime-audio"
    ]

    /// The lowercased schemes an Amazon SES tracking link may unwrap to: web, mail and phone only,
    /// narrower than `schemesOpenedOnEveryPlatform` (an SES-wrapped `facetime:` link is cancelled,
    /// pinned by `testAmazonSESTrackingLinkToDisallowedSchemeIsCancelled`). It must stay a subset
    /// of `schemesOpenedOnEveryPlatform`, or the Mac would refuse a destination the unwrap had just
    /// allowed.
    static let amazonSESDestinationSchemes: Set<String> = [
        "http",
        "https",
        "mailto",
        "tel"
    ]

    /// Whether `url`'s scheme, compared case-insensitively, is in `schemesOpenedOnEveryPlatform`.
    /// A URL with no scheme is refused.
    static func opensOnEveryPlatform(_ url: URL) -> Bool {
        schemeIsAllowed(url, in: schemesOpenedOnEveryPlatform)
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
