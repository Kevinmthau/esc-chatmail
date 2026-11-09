import UIKit
import WebKit
import XCTest
@testable import esc_chatmail

/// `LayoutAwareWKWebView` moved to `esc-chatmail/Platform/` and gained a Mac version (PR E). These
/// pin its iOS behavior: it reports layout and window moves, and `makeNonInteractive()` turns off
/// exactly what preview web views turned off inline before. The Mac `hitTest(_:)` override that
/// keeps preview cards from swallowing transcript scrolling cannot run until the test target gains
/// macOS (Mac plan, PR F).
@MainActor
final class LayoutAwareWKWebViewTests: XCTestCase {
    func testNewWebView_isInteractive() {
        let webView = LayoutAwareWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        XCTAssertTrue(webView.isUserInteractionEnabled)
        XCTAssertTrue(webView.scrollView.isScrollEnabled)
    }

    /// Revert-check: removing any line of the UIKit branch of
    /// `LayoutAwareWKWebView.makeNonInteractive()` fails this.
    func testMakeNonInteractive_onIOS_turnsOffScrollingBouncingAndInput() {
        let webView = LayoutAwareWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        webView.makeNonInteractive()

        XCTAssertFalse(webView.isUserInteractionEnabled)
        XCTAssertFalse(webView.scrollView.isScrollEnabled)
        XCTAssertFalse(webView.scrollView.bounces)
    }

    /// Revert-check: removing `LayoutAwareWKWebView.layoutSubviews()` fails this.
    func testLayout_onIOS_reportsALayoutChange() {
        let webView = LayoutAwareWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            configuration: WKWebViewConfiguration()
        )
        var reports = 0
        webView.onLayoutChange = { _ in reports += 1 }

        webView.setNeedsLayout()
        webView.layoutIfNeeded()

        XCTAssertGreaterThan(reports, 0)
    }

    /// Revert-check: removing `LayoutAwareWKWebView.didMoveToWindow()` fails this.
    func testMovingIntoAWindow_onIOS_reportsALayoutChange() throws {
        let window = try makeTestHostWindow()
        let webView = LayoutAwareWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var reportedWindows: [UIWindow?] = []
        webView.onLayoutChange = { reportedWebView in
            reportedWindows.append(reportedWebView.window)
        }

        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        XCTAssertTrue(reportedWindows.contains { $0 === window })
    }
}
