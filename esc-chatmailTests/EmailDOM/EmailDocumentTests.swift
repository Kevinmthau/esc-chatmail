import XCTest
@testable import esc_chatmail

/// Focused unit tests for the DOM wrapper used by the new HTML processing
/// pipeline. These verify the public surface that downstream callers depend
/// on without coupling tests to SwiftSoup internals.
final class EmailDocumentTests: XCTestCase {

    // MARK: - Parsing

    func testParse_nilInput_returnsNil() throws {
        XCTAssertNil(try EmailDocument.parse(nil))
    }

    func testTryParse_validHTML_returnsDocument() {
        let doc = EmailDocument.tryParse("<p>Hello, world.</p>")
        XCTAssertNotNil(doc)
    }

    func testTryParse_emptyString_returnsDocument() {
        // SwiftSoup parses empty into an empty document; this should not crash.
        let doc = EmailDocument.tryParse("")
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.plainText(preserveParagraphs: true), "")
    }

    // MARK: - Plain text extraction

    func testPlainText_simpleParagraph() {
        let doc = EmailDocument.tryParse("<p>Hello, world.</p>")
        XCTAssertEqual(doc?.plainText(preserveParagraphs: true), "Hello, world.")
    }

    func testPlainText_multipleParagraphs_separatedByParagraphBreak() {
        let html = "<p>First.</p><p>Second.</p>"
        let text = EmailDocument.tryParse(html)?.plainText(preserveParagraphs: true) ?? ""
        XCTAssertTrue(text.contains("First."))
        XCTAssertTrue(text.contains("Second."))
        XCTAssertTrue(text.contains("\n\n"), "Paragraph break should be preserved between blocks: \(text)")
    }

    func testPlainText_brTag_producesNewline() {
        let html = "<div>Line one<br>Line two</div>"
        let text = EmailDocument.tryParse(html)?.plainText(preserveParagraphs: true) ?? ""
        XCTAssertEqual(text, "Line one\nLine two")
    }

    func testPlainText_scriptAndStyle_excluded() {
        let html = """
        <div>Visible<script>alert('hi');</script><style>p { color: red; }</style></div>
        """
        let text = EmailDocument.tryParse(html)?.plainText(preserveParagraphs: true) ?? ""
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color"))
        XCTAssertTrue(text.contains("Visible"))
    }

    func testPlainText_decodesHTMLEntities() {
        let html = "<p>&amp; &lt;tag&gt; &nbsp;end</p>"
        let text = EmailDocument.tryParse(html)?.plainText(preserveParagraphs: true) ?? ""
        XCTAssertTrue(text.contains("&"))
        XCTAssertTrue(text.contains("<tag>"))
    }

    func testPlainText_stripsZeroWidthCharacters() {
        let html = "<p>Hello\u{200B}\u{200C}\u{200D}, world\u{FEFF}!</p>"
        let text = EmailDocument.tryParse(html)?.plainText(preserveParagraphs: true) ?? ""
        XCTAssertEqual(text, "Hello, world!")
    }

    // MARK: - Inline content IDs

    func testReferencedInlineContentIDs_imgSrc() {
        let html = """
        <p>Inline image:</p>
        <img src="cid:logo@example.com">
        <img src="cid:Header.png">
        <img src="https://example.com/external.png">
        """
        let ids = EmailDocument.tryParse(html)?.referencedInlineContentIDs() ?? []
        XCTAssertTrue(ids.contains("logo@example.com"))
        XCTAssertTrue(ids.contains("header.png"))
        XCTAssertFalse(ids.contains { $0.hasPrefix("https") })
    }

    func testReferencedInlineContentIDs_handlesAngleBracketsAndCasing() {
        let html = #"<img src="CID:&lt;abc-DEF&gt;">"#
        // Note: SwiftSoup decodes &lt; and &gt; in the attribute value.
        let ids = EmailDocument.tryParse(html)?.referencedInlineContentIDs() ?? []
        XCTAssertTrue(ids.contains("abc-def"), "Expected normalized id; got \(ids)")
    }

    func testReferencedInlineContentIDs_findsBackgroundAttribute() {
        let html = #"<table background="cid:bg.png"><tr><td>Cell</td></tr></table>"#
        let ids = EmailDocument.tryParse(html)?.referencedInlineContentIDs() ?? []
        XCTAssertTrue(ids.contains("bg.png"))
    }

    // MARK: - Normalization helper

    func testNormalizedContentID_strips_angle_brackets_and_lowercases() {
        XCTAssertEqual(EmailDocument.normalizedContentID("<ABC.JPG>"), "abc.jpg")
    }

    func testNormalizedContentID_returnsNilForEmpty() {
        XCTAssertNil(EmailDocument.normalizedContentID(nil))
        XCTAssertNil(EmailDocument.normalizedContentID(""))
        XCTAssertNil(EmailDocument.normalizedContentID("   "))
    }
}
