import XCTest
@testable import esc_chatmail

/// `EmailLinkSchemePolicy` decides which clicked email links the Mac hands to `NSWorkspace.open`
/// and which schemes an Amazon SES tracking link may unwrap to. It has no platform code, so it is
/// pinned here on iOS. `ExternalURLOpenerTests` pins the opener's use of it.
final class EmailLinkSchemePolicyTests: XCTestCase {
    func testAllowsOpeningOnMac_systemSchemes_isTrue() throws {
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
            XCTAssertTrue(EmailLinkSchemePolicy.allowsOpeningOnMac(url), string)
        }
    }

    /// Revert-check: removing `.lowercased()` from `EmailLinkSchemePolicy.schemeIsAllowed(_:in:)`
    /// makes this fail, refusing a web link whose author capitalized the scheme.
    func testAllowsOpeningOnMac_uppercaseScheme_isTrue() throws {
        let url = try XCTUnwrap(URL(string: "HTTPS://example.com"))

        XCTAssertTrue(EmailLinkSchemePolicy.allowsOpeningOnMac(url))
    }

    /// Schemes that `NSWorkspace.open` would hand to whichever app registered them, and that iOS's
    /// `canOpenURL` refuses because Info.plist does not list them as queried schemes. The app's own
    /// OAuth redirect scheme and `google:`, which iOS does list, are refused on the Mac too.
    ///
    /// Revert-check: making `EmailLinkSchemePolicy.allowsOpeningOnMac(_:)` return true for any
    /// scheme (the Mac's behavior before the policy) makes this fail.
    func testAllowsOpeningOnMac_otherAppSchemes_isFalse() throws {
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
            XCTAssertFalse(EmailLinkSchemePolicy.allowsOpeningOnMac(url), string)
        }
    }

    /// Revert-check: replacing the `guard let scheme` in
    /// `EmailLinkSchemePolicy.schemeIsAllowed(_:in:)` with a default of `"https"` makes this fail.
    func testAllowsOpeningOnMac_noScheme_isFalse() throws {
        let url = try XCTUnwrap(URL(string: "example.com/path"))

        XCTAssertNil(url.scheme)
        XCTAssertFalse(EmailLinkSchemePolicy.allowsOpeningOnMac(url))
        XCTAssertFalse(EmailLinkSchemePolicy.allowsAmazonSESDestination(url))
    }

    /// An SES tracking link must never unwrap to a destination the Mac then refuses, so the two
    /// lists that used to live apart are pinned to each other.
    ///
    /// Revert-check: adding a scheme to `EmailLinkSchemePolicy.amazonSESDestinationSchemes` that
    /// `macOpenableSchemes` lacks (say `"ftp"`) makes this fail.
    func testAmazonSESDestinationSchemes_areSubsetOfMacOpenableSchemes() {
        XCTAssertTrue(
            EmailLinkSchemePolicy.amazonSESDestinationSchemes.isSubset(of: EmailLinkSchemePolicy.macOpenableSchemes),
            "\(EmailLinkSchemePolicy.amazonSESDestinationSchemes.subtracting(EmailLinkSchemePolicy.macOpenableSchemes))"
        )
    }

    /// The SES unwrap keeps its narrower list after moving here: web, mail and phone only.
    ///
    /// Revert-check: pointing `EmailLinkSchemePolicy.allowsAmazonSESDestination(_:)` at
    /// `macOpenableSchemes` makes the `facetime:` and `sms:` assertions fail.
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
