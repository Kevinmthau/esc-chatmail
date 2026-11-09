import XCTest
@testable import esc_chatmail

/// `EmailTextLinkPolicy` is what a click on a link in the plain-text original-email reader does.
/// Before it, SwiftUI's default `openURL` opened any detected link, so the plain-text reader skipped
/// the WebView reader's private-network block and Amazon SES unwrap.
///
/// HONEST SCOPE: these pin the policy. Nothing hosts `OriginalEmailReadableView`, so removing its
/// `.opensEmailTextLinksWithReaderPolicy()` call, or the modifier's dispatch to `ExternalURLOpener`
/// and `FullInteractiveEmailWebView.logBlockedPrivateNetworkLink`, fails no test.
final class EmailTextLinkPolicyTests: XCTestCase {
    private func action(_ string: String) throws -> EmailTextLinkPolicy.Action {
        EmailTextLinkPolicy.action(for: try XCTUnwrap(URL(string: string)))
    }

    /// Revert-check: making `EmailTextLinkPolicy.action(for:)` return `.openExternally(url)`
    /// without consulting `FullInteractiveEmailWebView.navigationDecision` (what SwiftUI's default
    /// action did) makes this fail.
    func testAction_privateOrReservedHost_isBlocked() throws {
        XCTAssertEqual(
            try action("http://192.168.0.1/admin?action=reset"),
            .blockedPrivateNetwork(URL(string: "http://192.168.0.1/admin?action=reset")!)
        )
        XCTAssertEqual(
            try action("http://127.0.0.1/"),
            .blockedPrivateNetwork(URL(string: "http://127.0.0.1/")!)
        )
    }

    func testAction_publicWebLink_opensExternally() throws {
        XCTAssertEqual(
            try action("https://example.com/path"),
            .openExternally(URL(string: "https://example.com/path")!)
        )
    }

    func testAction_amazonSESTrackingLink_opensUnwrappedDestination() throws {
        let trackingURL = "https://vvd2lqhy.r.eu-west-3.awstrack.me/L0/https:%2F%2Fapi2.baback.co%2Fpublic%2Flabels%2Fexample-label/1/message-id/signature=258"

        XCTAssertEqual(
            try action(trackingURL),
            .openExternally(URL(string: "https://api2.baback.co/public/labels/example-label")!)
        )
    }

    func testAction_amazonSESTrackingLinkToPrivateHost_isBlocked() throws {
        let trackingURL = "https://vvd2lqhy.r.eu-west-3.awstrack.me/L0/http:%2F%2F127.0.0.1%2Fadmin/1/message-id/signature=258"

        XCTAssertEqual(try action(trackingURL), .blockedPrivateNetwork(URL(string: "http://127.0.0.1/admin")!))
    }

    func testAction_unsupportedScheme_isDiscarded() throws {
        XCTAssertEqual(try action("javascript:alert(1)"), .discard)
        XCTAssertEqual(try action("file:///etc/hosts"), .discard)
    }

    /// The WebView lets a data-detector link navigate in place; text has no in-place navigation,
    /// and the detector links this scheme in plain text like any other.
    ///
    /// Revert-check: mapping `.allow` to `.openExternally(url)` in `EmailTextLinkPolicy.action(for:)`
    /// makes this fail.
    func testAction_dataDetectorScheme_isDiscarded() throws {
        XCTAssertEqual(try action("x-apple-data-detectors://1"), .discard)
    }

    /// Another app's scheme still goes to `ExternalURLOpener`, which applies the platform gate
    /// (`canOpenURL` on iOS, `EmailLinkSchemePolicy.macOpenableSchemes` on the Mac).
    func testAction_otherAppScheme_isLeftToTheOpener() throws {
        XCTAssertEqual(try action("smb://host/share"), .openExternally(URL(string: "smb://host/share")!))
    }
}
