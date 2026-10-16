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

    // MARK: - sanitizeCSS: case-insensitive rules

    /// Every existing payload is lowercase; this pins the case option.
    ///
    /// Revert-check: the `.caseInsensitive` option on
    /// `HTMLCSSSanitizer.compiledCSSSanitizationRules`; compiling the rules
    /// without it lets `JAVASCRIPT:` through.
    func testSanitizeCSS_uppercaseJavascriptProtocol_removed() {
        let css = "background: url(JAVASCRIPT:alert(1))"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }

    /// Revert-check: `.caseInsensitive` on
    /// `HTMLCSSSanitizer.compiledCSSSanitizationRules` (mixed-case
    /// `Expression(` and `@IMPORT`).
    func testSanitizeCSS_mixedCaseExpressionAndImport_removed() {
        let css = "@IMPORT url(evil.css); width: Expression(alert('xss')); color: red"
        let result = sut.sanitizeCSS(css)
        XCTAssertFalse(result.lowercased().contains("@import"))
        XCTAssertFalse(result.lowercased().contains("expression("))
        XCTAssertTrue(result.contains("color: red"))
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

    /// A clean attribute is left byte-identical, and an upper-case or spaced
    /// `STYLE = "..."` attribute is still rewritten to `style="..."` even when
    /// its CSS needed no change.
    ///
    /// Revert-check: the inline loops in `HTMLCSSSanitizer.sanitizeInlineStyles`
    /// compare the existing text against the whole `style="…"` replacement
    /// (not the CSS alone) before skipping `replaceSubrange`; comparing the
    /// CSS alone would leave `STYLE = "color: red"` un-normalized.
    func testSanitizeInlineStyles_cleanAttributes_normalizesAttributeShapeOnly() {
        let clean = "<p style=\"color: red\">Hi</p><div style='margin: 0'>x</div>"
        XCTAssertEqual(sut.sanitizeInlineStyles(clean), "<p style=\"color: red\">Hi</p><div style=\"margin: 0\">x</div>")

        let spaced = "<p STYLE = \"color: red\">Hi</p>"
        XCTAssertEqual(sut.sanitizeInlineStyles(spaced), "<p style=\"color: red\">Hi</p>")
    }

    /// Revert-check: `.caseInsensitive` on
    /// `HTMLCSSSanitizer.compiledCSSSanitizationRules`, reached through the
    /// inline-attribute path.
    func testSanitizeInlineStyles_uppercaseJavascriptInAttribute_removed() {
        let html = "<div style=\"background: url(JAVASCRIPT:alert(1))\">x</div>"
        let result = sut.sanitizeInlineStyles(html)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
    }

    // MARK: - sanitizeStyleTags

    func testSanitizeStyleTags_javascriptInsideStyleTag_removed() {
        let html = "<style>.x { background: url(javascript:alert(1)); }</style>"
        let result = sut.sanitizeStyleTags(html)
        XCTAssertFalse(result.lowercased().contains("javascript:"))
        XCTAssertTrue(result.contains("<style>"))
        XCTAssertTrue(result.contains("</style>"))
    }

    /// The `sanitizedCSS` vs `cssContent` guard in
    /// `HTMLCSSSanitizer.sanitizeStyleTags` must only skip when nothing
    /// changed: a clean block comes back byte-identical and a dirty one is
    /// still rewritten with its tags intact.
    ///
    /// HONEST SCOPE: removing the guard re-inserts identical text, so this
    /// cannot fail on that revert; it fails if the guard ever skips a block
    /// whose CSS did change.
    func testSanitizeStyleTags_cleanBlockUnchangedAndDirtyBlockRewritten() {
        let clean = "<STYLE type=\"text/css\">.x { color: red; }</STYLE>"
        XCTAssertEqual(sut.sanitizeStyleTags(clean), clean)

        let dirty = "<style>.x { background: url(VBSCRIPT:msgbox(1)); }</style>"
        let result = sut.sanitizeStyleTags(dirty)
        XCTAssertFalse(result.lowercased().contains("vbscript:"))
        XCTAssertTrue(result.hasPrefix("<style>"))
        XCTAssertTrue(result.hasSuffix("</style>"))
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
