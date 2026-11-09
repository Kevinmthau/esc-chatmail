import UIKit
import WebKit
import XCTest
@testable import esc_chatmail

/// The Mac port moved every iOS-only `WKWebView` setting behind a shim in `esc-chatmail/Platform/`
/// (`WKWebView+Platform.swift`, `WKWebViewConfiguration+Platform.swift`). On iOS each shim must do
/// exactly what the shared code did inline before, so these tests pin the iOS values. The Mac
/// branches cannot run until the test target gains macOS (Mac plan, PR F).
@MainActor
final class WKWebViewPlatformTests: XCTestCase {
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

    /// WebKit hands `underPageBackgroundColor` back as a CGColor-backed `UIColor`, which `==`
    /// never equates with the color that was set, so compare resolved sRGB components instead.
    private func assertSameRGBA(
        _ actual: UIColor?,
        _ expected: UIColor,
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
    private func rgba(_ color: UIColor) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
            .map { String(Int(($0 * 255).rounded())) }
            .joined(separator: ",")
    }
}
