import XCTest
@testable import esc_chatmail

final class HTMLCSSSanitizerTests: XCTestCase {

    private var sut: HTMLCSSSanitizer!

    override func setUp() {
        super.setUp()
        sut = HTMLCSSSanitizer()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - sanitizeCSS: dangerous protocols

    func testSanitizeCSS_javascriptProtocol_removed() {
        let css = "background: url(javascript:alert(1))"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }

    func testSanitizeCSS_vbscriptProtocol_removed() {
        let css = "background: url(vbscript:msgbox(1))"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("vbscript:"))
    }

    // MARK: - sanitizeCSS: IE-specific

    func testSanitizeCSS_expression_removed() {
        let css = "width: expression(alert('xss'))"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("expression("))
    }

    func testSanitizeCSS_behavior_removed() {
        let css = ".x { behavior: url(htc); color: red; }"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("behavior:"))
        XCTAssertTrue(result.contains("color"))
    }

    // MARK: - sanitizeCSS: imports & bindings

    func testSanitizeCSS_importRule_removed() {
        let css = "@import url('evil.css'); color: red;"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("@import"))
        XCTAssertTrue(result.contains("color"))
    }

    func testSanitizeCSS_mozBinding_removed() {
        let css = ".x { -moz-binding: url(xbl); color: red; }"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("-moz-binding"))
        XCTAssertTrue(result.contains("color"))
    }

    func testSanitizeCSS_webkitBinding_removed() {
        let css = ".x { -webkit-binding: url(xbl); color: red; }"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("-webkit-binding"))
    }

    // MARK: - sanitizeCSS: url() with dangerous content

    func testSanitizeCSS_urlWithJavascript_removed() {
        let css = ".x { background: url('javascript:alert(1)'); }"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }

    func testSanitizeCSS_urlWithDataTextHtml_removed() {
        let css = ".x { background: url(\"data:text/html,<script>1</script>\"); }"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("data:text/html"))
    }

    // MARK: - sanitizeCSS: safe content preserved

    func testSanitizeCSS_safeStyles_preservedUnchanged() {
        let css = "color: #333; font-size: 16px; padding: 8px;"
        let result = sut.sanitizeCSS(css)
        XCTAssertEqual(result, css)
    }

    func testSanitizeCSS_safeUrlImage_preserved() {
        let css = "background: url(https://example.com/bg.png);"
        let result = sut.sanitizeCSS(css)
        XCTAssertTrue(result.contains("https://example.com/bg.png"))
    }

    // MARK: - sanitizeInlineStyles

    func testSanitizeInlineStyles_doubleQuotedJavascript_removed() {
        let html = "<div style=\"background: url(javascript:alert(1))\">x</div>"
        let result = sut.sanitizeInlineStyles(html)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }

    func testSanitizeInlineStyles_singleQuotedJavascript_removed() {
        let html = "<div style='background: url(javascript:alert(1))'>x</div>"
        let result = sut.sanitizeInlineStyles(html)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }

    func testSanitizeInlineStyles_singleQuotedAttribute_converttedToDoubleQuoted() {
        let html = "<div style='color: red'>x</div>"
        let result = sut.sanitizeInlineStyles(html)
        // Implementation rewrites both single- and double-quoted to double-quoted form
        XCTAssertTrue(result.contains("style=\"color: red\""))
    }

    func testSanitizeInlineStyles_safeInlineStyle_preserved() {
        let html = "<p style=\"color: red; font-size: 12px\">Hi</p>"
        let result = sut.sanitizeInlineStyles(html)
        XCTAssertTrue(result.contains("color: red"))
        XCTAssertTrue(result.contains("font-size: 12px"))
    }

    // MARK: - sanitizeStyleTags

    func testSanitizeStyleTags_javascriptInsideStyleTag_removed() {
        let html = "<style>.x { background: url(javascript:alert(1)); }</style>"
        let result = sut.sanitizeStyleTags(html)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
        XCTAssertTrue(result.contains("<style>"))
        XCTAssertTrue(result.contains("</style>"))
    }

    func testSanitizeStyleTags_multilineCSS_sanitized() {
        let html = """
        <style>
        .a { color: red; }
        .b { background: url(javascript:alert(1)); }
        .c { font-size: 10px; }
        </style>
        """
        let result = sut.sanitizeStyleTags(html)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
        XCTAssertTrue(result.contains("color: red"))
        XCTAssertTrue(result.contains("font-size: 10px"))
    }

    func testSanitizeStyleTags_expressionInsideStyleTag_removed() {
        let html = "<style>.x { width: expression(alert(1)); }</style>"
        let result = sut.sanitizeStyleTags(html)
        XCTAssertFalse(result.lowercased().contains("expression("))
    }

    func testSanitizeStyleTags_multipleStyleTags_allSanitized() {
        let html = """
        <style>.a { behavior: url(htc); }</style>
        <p>mid</p>
        <style>.b { width: expression(1); }</style>
        """
        let result = sut.sanitizeStyleTags(html)
        XCTAssertFalse(result.lowercased().contains("behavior:"))
        XCTAssertFalse(result.lowercased().contains("expression("))
    }

    // MARK: - sanitizeStyles: combined

    func testSanitizeStyles_sanitizesBothInlineAndTagStyles() {
        let html = """
        <style>.a { background: url(javascript:alert(1)); }</style>
        <div style="background: url(javascript:alert(2))">hi</div>
        """
        let result = sut.sanitizeStyles(html)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }
}
