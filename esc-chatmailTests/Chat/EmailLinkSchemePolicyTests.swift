import XCTest
@testable import esc_chatmail

/// `EmailLinkSchemePolicy` decides which clicked email links both platforms hand to the system
/// (the Mac's whole list, and the ones iOS opens without asking `canOpenURL`) and which schemes an
/// Amazon SES tracking link may unwrap to. It has no platform code, so it is pinned here on iOS.
/// `ExternalURLOpenerTests` pins the opener's use of it.
final class EmailLinkSchemePolicyTests: XCTestCase {
    func testOpensOnEveryPlatform_webMailPhoneMessagesFaceTime_isTrue() throws {
        let urls = [
            "https://example.com/path?query=1",
            "http://example.com",
            "mailto:someone@example.com",
            "tel:+15555550100",
            "sms:+15555550100",
            "facetime:someone@example.com",
            "facetime-audio:+15555550100"
        ]

        for string in urls {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertTrue(EmailLinkSchemePolicy.opensOnEveryPlatform(url), string)
        }
    }

    /// Revert-check: removing `.lowercased()` from `EmailLinkSchemePolicy.schemeIsAllowed(_:in:)`
    /// makes this fail, refusing a web link whose author capitalized the scheme.
    func testOpensOnEveryPlatform_uppercaseScheme_isTrue() throws {
        let url = try XCTUnwrap(URL(string: "HTTPS://example.com"))

        XCTAssertTrue(EmailLinkSchemePolicy.opensOnEveryPlatform(url))
    }

    /// Schemes that `NSWorkspace.open` would hand to whichever app registered them. They are outside
    /// the shared list, so the Mac refuses them and iOS leaves them to `canOpenURL`, which is not
    /// uniform about them: on the iOS 27.0 simulator it refused `zoommtg:` and accepted `smb:`. The
    /// app's own OAuth redirect scheme and `google:`, which Info.plist lists as queried schemes, are
    /// outside the list too.
    ///
    /// Revert-check: making `EmailLinkSchemePolicy.opensOnEveryPlatform(_:)` return true for any
    /// scheme (the Mac's behavior before the policy) makes this fail.
    func testOpensOnEveryPlatform_otherAppSchemes_isFalse() throws {
        let urls = [
            "ssh://admin@example.com",
            "smb://fileserver.example.com/share",
            "vnc://example.com",
            "afp://example.com/volume",
            "ftp://example.com/file",
            "itms-services://?action=download-manifest&url=https://example.com/app.plist",
            "x-apple-helpviewer://example",
            "zoommtg://zoom.us/join?confno=123",
            "slack://open",
            "google://search",
            "com.googleusercontent.apps.123-abc:/oauth2redirect?code=stolen",
            "file:///etc/hosts",
            "javascript:alert(1)",
            "data:text/html,hello"
        ]

        for string in urls {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertFalse(EmailLinkSchemePolicy.opensOnEveryPlatform(url), string)
        }
    }

    /// Revert-check: replacing the `guard let scheme` in
    /// `EmailLinkSchemePolicy.schemeIsAllowed(_:in:)` with a default of `"https"` makes this fail.
    func testOpensOnEveryPlatform_noScheme_isFalse() throws {
        let url = try XCTUnwrap(URL(string: "example.com/path"))

        XCTAssertNil(url.scheme)
        XCTAssertFalse(EmailLinkSchemePolicy.opensOnEveryPlatform(url))
        XCTAssertFalse(EmailLinkSchemePolicy.allowsAmazonSESDestination(url))
    }

    /// An SES tracking link must never unwrap to a destination the Mac then refuses, so the two
    /// lists that used to live apart are pinned to each other.
    ///
    /// Revert-check: adding a scheme to `EmailLinkSchemePolicy.amazonSESDestinationSchemes` that
    /// `schemesOpenedOnEveryPlatform` lacks (say `"ftp"`) makes this fail.
    func testAmazonSESDestinationSchemes_areSubsetOfSchemesOpenedOnEveryPlatform() {
        XCTAssertTrue(
            EmailLinkSchemePolicy.amazonSESDestinationSchemes.isSubset(of: EmailLinkSchemePolicy.schemesOpenedOnEveryPlatform),
            "\(EmailLinkSchemePolicy.amazonSESDestinationSchemes.subtracting(EmailLinkSchemePolicy.schemesOpenedOnEveryPlatform))"
        )
    }

    /// The SES unwrap keeps its narrower list after moving here: web, mail and phone only.
    ///
    /// Revert-check: pointing `EmailLinkSchemePolicy.allowsAmazonSESDestination(_:)` at
    /// `schemesOpenedOnEveryPlatform` makes the `facetime:` and `sms:` assertions fail.
    func testAllowsAmazonSESDestination_webMailAndPhoneOnly() throws {
        for string in ["https://example.com", "HTTP://example.com", "mailto:a@example.com", "tel:+15555550100"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertTrue(EmailLinkSchemePolicy.allowsAmazonSESDestination(url), string)
        }
        for string in ["facetime:user@example.com", "sms:+15555550100", "smb://host/share", "javascript:alert(1)"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertFalse(EmailLinkSchemePolicy.allowsAmazonSESDestination(url), string)
        }
    }
}
