#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import WebKit
import XCTest
@testable import esc_chatmail

/// The Mac port moved every iOS-only `WKWebView` setting behind a shim in `esc-chatmail/Platform/`
/// (`WKWebView+Platform.swift`, `WKWebViewConfiguration+Platform.swift`). On iOS each shim must do
/// exactly what the shared code did inline before, so the iOS tests pin the iOS values. The Mac
/// tests pin the substitutes in the "Mac equivalents" table of `docs/mac-app-plan.md` (PR E).
@MainActor
final class WKWebViewPlatformTests: XCTestCase {
    #if os(iOS)
    /// Revert-check: emptying the UIKit branch of `WKWebView.applyInterfaceStyle(_:)` fails this.
    func testApplyInterfaceStyle_onIOS_overridesTheTraitStyle() {
        let webView = WKWebView()

        for style in [PlatformInterfaceStyle.light, .dark, .unspecified] {
            webView.applyInterfaceStyle(style)
            XCTAssertEqual(webView.overrideUserInterfaceStyle, style)
        }
    }

    /// Every surface starts at another color, as when a preview's theme flips between updates, so
    /// each assignment has to overwrite it. (Unset, WebKit reports `underPageBackgroundColor` as
    /// the view's background, which would hide a missing assignment.)
    ///
    /// Revert-check: removing any of the four assignments in the UIKit branch of
    /// `WKWebView.applyNativeBackgroundColor(_:)` fails this.
    func testApplyNativeBackgroundColor_onIOS_makesTheViewNonOpaqueAndPaintsEverySurface() {
        let webView = WKWebView()
        let previousColor = UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let color = UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        webView.isOpaque = true
        webView.backgroundColor = previousColor
        webView.scrollView.backgroundColor = previousColor
        webView.underPageBackgroundColor = previousColor

        webView.applyNativeBackgroundColor(color)

        XCTAssertFalse(webView.isOpaque)
        assertSameRGBA(webView.backgroundColor, color)
        assertSameRGBA(webView.scrollView.backgroundColor, color)
        assertSameRGBA(webView.underPageBackgroundColor, color)
    }

    /// Revert-check: emptying the UIKit branch of `WKWebView.applyFullReaderScrollInsets()` fails this.
    func testApplyFullReaderScrollInsets_onIOS_neverAdjustsContentInsetsButAdjustsIndicators() {
        let webView = WKWebView()
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false

        webView.applyFullReaderScrollInsets()

        XCTAssertEqual(webView.scrollView.contentInsetAdjustmentBehavior, .never)
        XCTAssertTrue(webView.scrollView.automaticallyAdjustsScrollIndicatorInsets)
    }

    /// Revert-check: emptying the UIKit branch of `WKWebView.resetScrollPosition()` fails this.
    func testResetScrollPosition_onIOS_returnsTheScrollViewToTheTop() {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        webView.scrollView.contentSize = CGSize(width: 320, height: 2_000)
        webView.scrollView.contentOffset = CGPoint(x: 0, y: 600)
        XCTAssertEqual(webView.scrollView.contentOffset.y, 600, "Precondition: the page is scrolled")

        webView.resetScrollPosition()

        XCTAssertEqual(webView.scrollView.contentOffset, .zero)
    }

    /// Revert-check: emptying `WKWebViewConfiguration.applyFullReaderMediaAndDataDetectorSettings()`
    /// fails this (`allowsInlineMediaPlayback` defaults to true on iPhone, data detectors to none).
    func testFullReaderConfiguration_onIOS_disablesInlineMediaAndKeepsDataDetectors() {
        let configuration = FullInteractiveEmailWebView.makeConfiguration(
            cidHandler: CIDSchemeHandler(message: nil)
        )

        XCTAssertFalse(configuration.allowsInlineMediaPlayback)
        XCTAssertEqual(configuration.dataDetectorTypes, [.phoneNumber, .link, .address])
    }

    /// The full reader and the warm pool both go through `FullInteractiveEmailWebView`, so they
    /// must keep forcing light, Mail's insets, and the opaque-free theme background on iOS.
    ///
    /// Revert-check: dropping the `applyFullReaderScrollInsets()` call from `applySettings(to:)` or
    /// the `applyNativeBackgroundColor(_:)` call from `applyBackgroundAppearance(to:)` fails this.
    ///
    /// HONEST SCOPE: both functions force light, so dropping one `applyInterfaceStyle(.light)` call
    /// alone does not fail this; only dropping both does.
    func testFullInteractiveSettings_onIOS_forceLightKeepMailInsetsAndPaintTheOriginalTheme() throws {
        let webView = WKWebView(
            frame: .zero,
            configuration: FullInteractiveEmailWebView.makeConfiguration(cidHandler: CIDSchemeHandler(message: nil))
        )
        let theme = HTMLDisplayWrapper.theme(isDarkMode: false, displayPurpose: .original)
        let themeColor = PlatformColor(hex: theme.backgroundColorHex)

        FullInteractiveEmailWebView.applySettings(to: webView)
        FullInteractiveEmailWebView.applyBackgroundAppearance(to: webView)

        XCTAssertEqual(webView.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(webView.scrollView.contentInsetAdjustmentBehavior, .never)
        XCTAssertFalse(webView.isOpaque)
        let expectedColor = try XCTUnwrap(themeColor)
        assertSameRGBA(webView.underPageBackgroundColor, expectedColor)
        assertSameRGBA(webView.scrollView.backgroundColor, expectedColor)
    }

    #elseif os(macOS)
    /// Revert-check: emptying the AppKit branch of `WKWebView.applyInterfaceStyle(_:)` fails this.
    func testApplyInterfaceStyle_onMac_setsTheMatchingAppearance() {
        let webView = WKWebView()

        webView.applyInterfaceStyle(.dark)
        XCTAssertEqual(webView.appearance?.name, .darkAqua)

        webView.applyInterfaceStyle(.light)
        XCTAssertEqual(webView.appearance?.name, .aqua)

        webView.applyInterfaceStyle(.unspecified)
        XCTAssertNil(webView.appearance, "Unspecified must inherit the window's appearance")
    }

    /// On the Mac only the overscroll area is painted; the page itself stays opaque, because only
    /// private API makes a Mac web view see-through. The color starts elsewhere so a missing
    /// assignment cannot pass on WebKit's default.
    ///
    /// Revert-check: removing the assignment in the AppKit branch of
    /// `WKWebView.applyNativeBackgroundColor(_:)` fails this.
    func testApplyNativeBackgroundColor_onMac_paintsTheUnderPageBackground() {
        let webView = WKWebView()
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        webView.underPageBackgroundColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)

        webView.applyNativeBackgroundColor(color)

        assertSameRGBA(webView.underPageBackgroundColor, color)
    }

    /// The full reader has no `scrollView` on the Mac, so its pool checkin scrolls with a script.
    ///
    /// Revert-check: emptying the AppKit branch of `WKWebView.resetScrollPosition()` fails this.
    func testResetScrollPosition_onMac_returnsThePageToTheTop() async throws {
        let window = try makeTestHostWindow()
        defer { window.close() }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.contentView?.addSubview(webView)
        let navigation = NavigationFinishRecorder()
        webView.navigationDelegate = navigation
        webView.loadHTMLString(
            "<html><body style=\"margin:0\"><div style=\"height:4000px\">Tall</div></body></html>",
            baseURL: nil
        )
        await waitUntil { navigation.didFinish }
        // The script ends on a value: the async `evaluateJavaScript` cannot return `undefined`.
        let scrolledY = try await scrollY(of: webView, after: "window.scrollTo(0, 600);")
        XCTAssertEqual(scrolledY, 600, "Precondition: the page is scrolled")

        webView.resetScrollPosition()

        var resetY = scrolledY
        let deadline = Date().addingTimeInterval(5)
        while resetY != 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            resetY = try await scrollY(of: webView)
        }
        XCTAssertEqual(resetY, 0)
    }

    /// The full reader and the warm pool both go through `FullInteractiveEmailWebView`, so on the
    /// Mac they must force light (Aqua) and paint the original theme behind the page.
    ///
    /// Revert-check: dropping the `applyNativeBackgroundColor(_:)` call from
    /// `applyBackgroundAppearance(to:)` fails this.
    ///
    /// HONEST SCOPE: both functions force light, so dropping one `applyInterfaceStyle(.light)` call
    /// alone does not fail this; only dropping both does.
    func testFullInteractiveSettings_onMac_forceLightAndPaintTheOriginalTheme() throws {
        let webView = WKWebView(
            frame: .zero,
            configuration: FullInteractiveEmailWebView.makeConfiguration(cidHandler: CIDSchemeHandler(message: nil))
        )
        let theme = HTMLDisplayWrapper.theme(isDarkMode: false, displayPurpose: .original)
        let expectedColor = try XCTUnwrap(PlatformColor(hex: theme.backgroundColorHex))
        webView.underPageBackgroundColor = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)

        FullInteractiveEmailWebView.applySettings(to: webView)
        FullInteractiveEmailWebView.applyBackgroundAppearance(to: webView)

        XCTAssertEqual(webView.appearance?.name, .aqua)
        assertSameRGBA(webView.underPageBackgroundColor, expectedColor)
    }

    private func scrollY(of webView: WKWebView, after script: String = "") async throws -> Double {
        let value = try await webView.evaluateJavaScript(script + "window.scrollY")
        return try XCTUnwrap((value as? NSNumber)?.doubleValue, "window.scrollY returned \(String(describing: value))")
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
    #endif

    /// WebKit hands `underPageBackgroundColor` back as a CGColor-backed color, which `==` never
    /// equates with the color that was set, so compare resolved sRGB components instead.
    private func assertSameRGBA(
        _ actual: PlatformColor?,
        _ expected: PlatformColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Expected a color, got nil", file: file, line: line)
            return
        }
        XCTAssertEqual(rgba(actual), rgba(expected), file: file, line: line)
    }

    /// Components rounded to 1/255, as strings so a failure prints both colors.
    private func rgba(_ color: PlatformColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(iOS)
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #elseif os(macOS)
        guard let resolved = color.usingColorSpace(.sRGB) else {
            return "not convertible to sRGB: \(color)"
        }
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return [red, green, blue, alpha]
            .map { String(Int(($0 * 255).rounded())) }
            .joined(separator: ",")
    }
}

#if os(macOS)
/// Records when a navigation finishes, for a test that has to wait for a page before scrolling it.
private final class NavigationFinishRecorder: NSObject, WKNavigationDelegate {
    private(set) var didFinish = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
    }
}
#endif
