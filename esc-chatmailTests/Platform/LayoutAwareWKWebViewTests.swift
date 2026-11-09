#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import WebKit
import XCTest
@testable import esc_chatmail

/// `LayoutAwareWKWebView` moved to `esc-chatmail/Platform/` and gained a Mac version (PR E). These
/// pin both: it reports layout and window moves, and `makeNonInteractive()` turns off every kind of
/// input. On iOS that is exactly what preview web views turned off inline before; on the Mac it is
/// the `hitTest(_:)` override that keeps preview cards from swallowing transcript scrolling.
@MainActor
final class LayoutAwareWKWebViewTests: XCTestCase {
    #if os(iOS)
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
    #elseif os(macOS)
    /// The point `hitTest(_:)` takes is in the superview's coordinates; with no superview that is
    /// the frame's own space, so the middle of the frame is inside the view.
    private static let frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    private static let pointInside = NSPoint(x: 160, y: 100)

    func testNewWebView_onMac_takesClicksAndScrolling() {
        let webView = LayoutAwareWKWebView(frame: Self.frame, configuration: WKWebViewConfiguration())

        XCTAssertNotNil(webView.hitTest(Self.pointInside))
    }

    /// Without this, a preview card swallows transcript scrolling: in the WebKit spike, a 150 pt
    /// trackpad gesture over a card moved the transcript 0 pt.
    ///
    /// Revert-check: removing `acceptsUserInput = false` from the AppKit branch of
    /// `LayoutAwareWKWebView.makeNonInteractive()`, or the guard in its `hitTest(_:)` override,
    /// fails this.
    func testMakeNonInteractive_onMac_hitTestsToNothing() {
        let webView = LayoutAwareWKWebView(frame: Self.frame, configuration: WKWebViewConfiguration())

        webView.makeNonInteractive()

        XCTAssertNil(webView.hitTest(Self.pointInside))
    }

    /// Revert-check: removing `LayoutAwareWKWebView.setFrameSize(_:)` fails this.
    func testSetFrameSize_onMac_reportsALayoutChange() {
        let webView = LayoutAwareWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var reports = 0
        webView.onLayoutChange = { _ in reports += 1 }

        webView.setFrameSize(Self.frame.size)

        XCTAssertGreaterThan(reports, 0)
    }

    /// Revert-check: removing `LayoutAwareWKWebView.viewDidMoveToWindow()` fails this.
    func testMovingIntoAWindow_onMac_reportsALayoutChange() throws {
        let window = try makeTestHostWindow()
        defer { window.close() }
        let contentView = try XCTUnwrap(window.contentView)
        let webView = LayoutAwareWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var reportedWindows: [NSWindow?] = []
        webView.onLayoutChange = { reportedWebView in
            reportedWindows.append(reportedWebView.window)
        }

        contentView.addSubview(webView)
        defer { webView.removeFromSuperview() }

        XCTAssertTrue(reportedWindows.contains { $0 === window })
    }
    #endif
}
