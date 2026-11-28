import WebKit
import XCTest
@testable import esc_chatmail

/// The preview web views' one navigation policy (architecture review 2026-11,
/// `web-content-rendering#6`): their own document loads and reloads, and nothing else, and no
/// refused scheme loads whatever the navigation type.
final class EmailPreviewNavigationPolicyTests: XCTestCase {
    private let baseURL = URL(string: "https://sender.example/")!

    /// Revert-check: dropping the scheme screen from `EmailPreviewNavigationPolicy.allows` fails
    /// the refused-scheme rows.
    func testAllows_table() throws {
        let rows: [(WKNavigationType, String?, Bool)] = [
            (.other, baseURL.absoluteString, true),
            (.other, "about:blank", true),
            (.reload, baseURL.absoluteString, true),
            (.other, nil, true),
            (.other, "javascript:alert(1)", false),
            (.reload, "JavaScript:alert(1)", false),
            (.other, "vbscript:msgbox", false),
            (.other, "file:///etc/hosts", false),
            (.linkActivated, "https://example.com/", false),
            (.formSubmitted, baseURL.absoluteString, false),
            (.formResubmitted, baseURL.absoluteString, false),
            (.backForward, baseURL.absoluteString, false)
        ]
        for (type, string, expected) in rows {
            let url = try string.map { try XCTUnwrap(URL(string: $0)) }
            XCTAssertEqual(
                EmailPreviewNavigationPolicy.allows(navigationType: type, url: url),
                expected,
                "\(type.rawValue) \(string ?? "nil")"
            )
        }
    }

    /// The reader refuses the same schemes, through the same screen.
    func testReaderPolicy_refusesTheScreensSchemes() throws {
        for scheme in EmailNavigationSchemeScreen.refusedSchemes.sorted() {
            let url = try XCTUnwrap(URL(string: "\(scheme):payload"))
            XCTAssertEqual(
                FullInteractiveEmailWebView.navigationDecision(navigationType: .other, url: url),
                .cancel,
                scheme
            )
        }
    }

    /// Both preview delegates decide through the policy, and neither writes the rule inline again.
    ///
    /// Revert-check: putting the inline `.other || .reload` rule back in either delegate fails
    /// this.
    func testPreviewDelegates_useThePolicy() throws {
        for path in [
            "esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift",
            "esc-chatmail/Services/Preview/EmailPreviewSnapshotRenderer.swift"
        ] {
            let source = try repositorySource(path)
            XCTAssertTrue(source.contains("EmailPreviewNavigationPolicy.allows("), path)
            XCTAssertFalse(source.contains("navigationAction.navigationType == .other"), path)
        }
    }
}
