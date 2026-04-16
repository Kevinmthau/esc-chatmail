import XCTest
@testable import esc_chatmail

final class HTMLURLSanitizerTests: XCTestCase {

    private var sut: HTMLURLSanitizer!

    override func setUp() {
        super.setUp()
        sut = HTMLURLSanitizer()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - isURLSafe: allowed protocols

    func testIsURLSafe_httpsURL_returnsTrue() {
        XCTAssertTrue(sut.isURLSafe("https://example.com/path"))
    }

    func testIsURLSafe_httpURL_returnsTrue() {
        XCTAssertTrue(sut.isURLSafe("http://example.com"))
    }

    func testIsURLSafe_mailtoURL_returnsTrue() {
        XCTAssertTrue(sut.isURLSafe("mailto:alice@example.com"))
    }

    func testIsURLSafe_telURL_returnsTrue() {
        XCTAssertTrue(sut.isURLSafe("tel:+15555555555"))
    }

    func testIsURLSafe_cidURL_returnsTrue() {
        XCTAssertTrue(sut.isURLSafe("cid:image001@abc.png"))
    }

    func testIsURLSafe_relativeURL_returnsTrue() {
        XCTAssertTrue(sut.isURLSafe("/path/to/thing"))
        XCTAssertTrue(sut.isURLSafe("#anchor"))
        XCTAssertTrue(sut.isURLSafe("?query=1"))
        XCTAssertTrue(sut.isURLSafe("relative/path"))
    }

    // MARK: - isURLSafe: dangerous protocols

    func testIsURLSafe_javascriptProtocol_returnsFalse() {
        XCTAssertFalse(sut.isURLSafe("javascript:alert(1)"))
    }

    func testIsURLSafe_vbscriptProtocol_returnsFalse() {
        XCTAssertFalse(sut.isURLSafe("vbscript:msgbox(1)"))
    }

    func testIsURLSafe_unknownProtocol_returnsFalse() {
        XCTAssertFalse(sut.isURLSafe("file:///etc/passwd"))
        XCTAssertFalse(sut.isURLSafe("ftp://example.com"))
    }

    // MARK: - isURLSafe: encoding bypass attempts

    func testIsURLSafe_uppercaseJavascript_returnsFalse() {
        XCTAssertFalse(sut.isURLSafe("JAVASCRIPT:alert(1)"))
        XCTAssertFalse(sut.isURLSafe("JavaScript:alert(1)"))
    }

    func testIsURLSafe_percentEncodedJavascript_returnsFalse() {
        XCTAssertFalse(sut.isURLSafe("java%73cript:alert(1)"))
        XCTAssertFalse(sut.isURLSafe("%6Aavascript:alert(1)"))
    }

    func testIsURLSafe_doubleEncodedJavascript_returnsFalse() {
        XCTAssertFalse(sut.isURLSafe("java%2573cript:alert(1)"))
    }

    func testIsURLSafe_htmlEntityEncodedJavascript_returnsFalse() {
        XCTAssertFalse(sut.isURLSafe("&#106;avascript:alert(1)"))
        XCTAssertFalse(sut.isURLSafe("&#x6A;avascript:alert(1)"))
    }

    func testIsURLSafe_javascriptWithWhitespaceInProtocol_returnsFalse() {
        XCTAssertFalse(sut.isURLSafe("java\tscript:alert(1)"))
        XCTAssertFalse(sut.isURLSafe("java\nscript:alert(1)"))
        XCTAssertFalse(sut.isURLSafe("  javascript:alert(1)"))
    }

    // MARK: - isDataURL

    func testIsDataURL_pngImage_returnsTrue() {
        XCTAssertTrue(sut.isDataURL("data:image/png;base64,iVBORw0KGgo="))
    }

    func testIsDataURL_jpegImage_returnsTrue() {
        XCTAssertTrue(sut.isDataURL("data:image/jpeg;base64,/9j/4AAQ"))
    }

    func testIsDataURL_gifImage_returnsTrue() {
        XCTAssertTrue(sut.isDataURL("data:image/gif;base64,R0lGOD"))
    }

    func testIsDataURL_svg_returnsFalse() {
        // SVGs can contain scripts — must not be accepted as image data URLs
        XCTAssertFalse(sut.isDataURL("data:image/svg+xml;base64,PHN2Zw=="))
    }

    func testIsDataURL_htmlDataURL_returnsFalse() {
        XCTAssertFalse(sut.isDataURL("data:text/html,<script>alert(1)</script>"))
    }

    // MARK: - sanitizeURLs: href

    func testSanitizeURLs_hrefJavascript_rewrittenToHash() {
        let html = "<a href=\"javascript:alert(1)\">Click</a>"
        let result = sut.sanitizeURLs(html)
        XCTAssertFalse(result.contains("javascript:"))
        XCTAssertTrue(result.contains("href=\"#\""))
    }

    func testSanitizeURLs_hrefHttpsPreserved() {
        let html = "<a href=\"https://safe.com\">Safe</a>"
        let result = sut.sanitizeURLs(html)
        XCTAssertTrue(result.contains("https://safe.com"))
    }

    func testSanitizeURLs_hrefMailtoPreserved() {
        let html = "<a href=\"mailto:me@example.com\">Email</a>"
        let result = sut.sanitizeURLs(html)
        XCTAssertTrue(result.contains("mailto:me@example.com"))
    }

    func testSanitizeURLs_mixedSafeAndUnsafeHrefs_sanitizesOnlyUnsafe() {
        let html = """
        <a href="https://safe.com">Safe</a>
        <a href="javascript:alert(1)">Bad</a>
        <a href="mailto:a@b.c">Email</a>
        """
        let result = sut.sanitizeURLs(html)
        XCTAssertTrue(result.contains("https://safe.com"))
        XCTAssertTrue(result.contains("mailto:a@b.c"))
        XCTAssertFalse(result.contains("javascript:"))
    }

    // MARK: - sanitizeURLs: src

    func testSanitizeURLs_srcJavascript_replacedWithTransparentPixel() {
        let html = "<img src=\"javascript:alert(1)\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertFalse(result.contains("javascript:"))
        XCTAssertTrue(result.contains("data:image/gif;base64"))
    }

    func testSanitizeURLs_srcDataTextHtml_replacedWithTransparentPixel() {
        let html = "<img src=\"data:text/html,<script>alert(1)</script>\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertFalse(result.contains("text/html"))
        XCTAssertFalse(result.contains("<script>"))
    }

    func testSanitizeURLs_srcEmptyURL_replacedWithTransparentPixel() {
        let html = "<img src=\"\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertTrue(result.contains("data:image/gif;base64"))
    }

    func testSanitizeURLs_srcHttpsPreserved() {
        let html = "<img src=\"https://example.com/logo.png\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertTrue(result.contains("https://example.com/logo.png"))
    }

    func testSanitizeURLs_srcCidPreserved() {
        let html = "<img src=\"cid:image001@example.com\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertTrue(result.contains("cid:image001@example.com"))
    }

    func testSanitizeURLs_srcSafeDataImage_preserved() {
        let html = "<img src=\"data:image/png;base64,iVBORw0KGgo=\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertTrue(result.contains("data:image/png;base64,iVBORw0KGgo="))
    }

    // MARK: - sanitizeURLs: modern image format hints

    func testSanitizeURLs_formatAuto_rewrittenToJpeg() {
        let html = "<img src=\"https://cdn.example.com/img.png?format=auto\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertFalse(result.contains("format=auto"))
        XCTAssertTrue(result.contains("format=jpeg"))
    }

    func testSanitizeURLs_fmWebp_rewrittenToJpg() {
        let html = "<img src=\"https://cdn.example.com/img?fm=webp\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertFalse(result.contains("fm=webp"))
        XCTAssertTrue(result.contains("fm=jpg"))
    }

    func testSanitizeURLs_formatAvif_rewrittenToJpeg() {
        let html = "<img src=\"https://cdn.example.com/img?format=avif\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertFalse(result.contains("format=avif"))
        XCTAssertTrue(result.contains("format=jpeg"))
    }

    func testSanitizeURLs_formatJpegPreservesExisting() {
        let html = "<img src=\"https://cdn.example.com/img?format=jpeg\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertTrue(result.contains("format=jpeg"))
    }

    func testSanitizeURLs_disableRewriteFlag_preservesFormatAuto() {
        let html = "<img src=\"https://cdn.example.com/img?format=auto\">"
        let result = sut.sanitizeURLs(html, rewriteModernFormatQueryHints: false)
        XCTAssertTrue(result.contains("format=auto"))
    }

    // MARK: - sanitizeURLs: Cloudflare CDN rewriting

    func testSanitizeURLs_cloudflareCdnAutoFormat_rewrittenToJpeg() {
        let html = "<img src=\"https://example.com/cdn-cgi/image/width=800,format=auto/path.png\">"
        let result = sut.sanitizeURLs(html)
        XCTAssertFalse(result.contains("format=auto"))
        XCTAssertTrue(result.contains("format=jpeg"))
    }
}
