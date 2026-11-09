import XCTest
@testable import esc_chatmail

/// `MacExternalURLSchemePolicy` decides which clicked email links the Mac hands to
/// `NSWorkspace.open`. It has no platform code, so it is pinned here on iOS.
///
/// HONEST SCOPE: the test target is iOS-only, so nothing here proves the Mac branch of
/// `ExternalURLOpener.open(_:)` consults the policy, or that the plain-text reader's links reach
/// that opener on the Mac (`View.opensEmailLinksThroughExternalURLOpener()`); removing either fails
/// no test. These pin the policy itself.
final class MacExternalURLSchemePolicyTests: XCTestCase {
    func testAllowsOpening_systemSchemes_isTrue() throws {
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
            XCTAssertTrue(MacExternalURLSchemePolicy.allowsOpening(url), string)
        }
    }

    /// Revert-check: removing `.lowercased()` from `MacExternalURLSchemePolicy.allowsOpening(_:)`
    /// makes this fail, refusing a web link whose author capitalized the scheme.
    func testAllowsOpening_uppercaseScheme_isTrue() throws {
        let url = try XCTUnwrap(URL(string: "HTTPS://example.com"))

        XCTAssertTrue(MacExternalURLSchemePolicy.allowsOpening(url))
    }

    /// Schemes that `NSWorkspace.open` would hand to whichever app registered them, and that iOS's
    /// `canOpenURL` refuses because the app declares no queried schemes.
    ///
    /// Revert-check: making `MacExternalURLSchemePolicy.allowsOpening(_:)` return true for any
    /// scheme (the Mac's behavior before the policy) makes this fail.
    func testAllowsOpening_otherAppSchemes_isFalse() throws {
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
            "file:///etc/hosts",
            "javascript:alert(1)",
            "data:text/html,hello"
        ]

        for string in urls {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertFalse(MacExternalURLSchemePolicy.allowsOpening(url), string)
        }
    }

    /// Revert-check: replacing the `guard let scheme` in
    /// `MacExternalURLSchemePolicy.allowsOpening(_:)` with a default of `"https"` makes this fail.
    func testAllowsOpening_noScheme_isFalse() throws {
        let url = try XCTUnwrap(URL(string: "example.com/path"))

        XCTAssertNil(url.scheme)
        XCTAssertFalse(MacExternalURLSchemePolicy.allowsOpening(url))
    }
}
