import XCTest
@testable import esc_chatmail

/// Tests for the DOM-based quote remover. These intentionally mirror a subset
/// of `HTMLQuoteRemoverTests` so that the DOM implementation can be validated
/// for behavioral parity with the legacy regex implementation.
///
/// Unlike `HTMLQuoteRemoverTests`, these tests don't compare HTML strings
/// directly (SwiftSoup re-emits HTML with normalized attribute order, which
/// would make exact-match comparisons flaky). They check semantic outcomes:
/// is the response visible? Is the quoted content gone?
final class EmailDOMQuoteRemoverTests: XCTestCase {

    // MARK: - Helpers

    private func plainText(_ html: String?) -> String {
        guard let html else { return "" }
        return EmailDocument.tryParse(html)?.plainText(preserveParagraphs: true) ?? ""
    }

    // MARK: - Nil / empty

    func testRemoveQuotes_nilInput_returnsNil() {
        XCTAssertNil(EmailDOMQuoteRemover.removeQuotes(from: nil))
    }

    func testRemoveQuotes_emptyString_returnsString() {
        let result = EmailDOMQuoteRemover.removeQuotes(from: "")
        XCTAssertNotNil(result)
    }

    // MARK: - Gmail patterns

    func testRemoveQuotes_gmailQuote_dropsQuotedContent() {
        let html = """
        <p>My response here.</p>
        <div class="gmail_quote"><p>Original quoted content</p></div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("My response here."))
        XCTAssertFalse(text.contains("Original quoted content"))
    }

    func testRemoveQuotes_gmailQuote_withMultipleClasses() {
        let html = """
        <p>Visible body.</p>
        <div class="gmail_quote gmail_quote_container"><p>Quoted</p></div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Visible body."))
        XCTAssertFalse(text.contains("Quoted"))
    }

    func testRemoveQuotes_gmailAttr_dropsAttribution() {
        let html = """
        <p>Reply.</p>
        <div class="gmail_attr">On Mon, Jan 15, 2024 at 10:30 AM John wrote:</div>
        <div class="gmail_quote"><p>Quoted content</p></div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Reply."))
        XCTAssertFalse(text.contains("John wrote"))
        XCTAssertFalse(text.contains("Quoted content"))
    }

    // MARK: - Apple Mail

    func testRemoveQuotes_appleMailBlockquote_dropsCite() {
        let html = """
        <p>Reply.</p>
        <blockquote type="cite"><p>Earlier message</p></blockquote>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Reply."))
        XCTAssertFalse(text.contains("Earlier message"))
    }

    // MARK: - Outlook structural boundary

    func testRemoveQuotes_outlookReferenceContainer_truncates() {
        let html = """
        <p>Visible.</p>
        <div id="mail-editor-reference-message-container"><p>Quote</p></div>
        <p>Stale tail content</p>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Visible."))
        XCTAssertFalse(text.contains("Quote"))
        XCTAssertFalse(text.contains("Stale tail content"),
                       "Truncation at structural boundary should remove content after the boundary too.")
    }

    func testRemoveQuotes_outlookReferenceContainer_prefixedId_truncates() {
        // Outlook for the web prefixes IDs with `x_`.
        let html = """
        <p>Visible.</p>
        <div id="x_mail-editor-reference-message-container"><p>Quote</p></div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Visible."))
        XCTAssertFalse(text.contains("Quote"))
    }

    // MARK: - Text marker ("On ... wrote:")

    func testRemoveQuotes_onDateWrote_truncatesAtMarker() {
        let html = """
        <div>My reply.</div>
        <div>On Mon, Jan 15, 2024 at 10:30 AM John wrote:</div>
        <blockquote>Earlier message</blockquote>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("My reply."))
        XCTAssertFalse(text.contains("John wrote"))
        XCTAssertFalse(text.contains("Earlier message"))
    }

    // MARK: - Signature mode

    func testRemoveQuotes_signatureMode_removesGmailSignature() {
        let html = """
        <p>Body.</p>
        <div class="gmail_signature">--<br>Sent from my iPhone</div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))
        XCTAssertTrue(text.contains("Body."))
        XCTAssertFalse(text.contains("Sent from my iPhone"))
    }

    func testRemoveQuotes_quotedOnly_keepsSignature() {
        // In .quotedOnly mode the signature should remain, so callers using
        // the lighter mode can still see compose-time signatures.
        let html = """
        <p>Body.</p>
        <div class="gmail_signature">--<br>Sent from my iPhone</div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedOnly))
        XCTAssertTrue(text.contains("Body."))
        XCTAssertTrue(text.contains("Sent from my iPhone"))
    }

    // MARK: - Fragment vs document preservation

    func testRemoveQuotes_fragmentInput_returnsFragmentNotWrappedDocument() {
        // Reply quoting in MimeBuilder+Reply passes a fragment and expects a
        // fragment back. Wrapping a fragment with `<html><body>` would
        // corrupt outgoing MIME parts.
        let html = "<p>Body.</p><div class=\"gmail_quote\"><p>Quote</p></div>"
        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        XCTAssertFalse(result.lowercased().contains("<html"),
                       "Fragment input should not gain <html> wrapper, got: \(result)")
        XCTAssertFalse(result.lowercased().contains("<body"),
                       "Fragment input should not gain <body> wrapper, got: \(result)")
    }

    func testRemoveQuotes_documentInput_returnsFullDocument() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Test</title></head>
        <body><p>Body.</p><div class="gmail_quote"><p>Quote</p></div></body>
        </html>
        """
        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        XCTAssertTrue(result.lowercased().contains("<html"),
                      "Document input should keep <html> wrapper, got: \(result)")
    }

    // MARK: - Idempotence

    func testRemoveQuotes_isIdempotent() {
        let html = """
        <p>Visible.</p>
        <div class="gmail_quote"><p>Quoted</p></div>
        """
        let pass1 = EmailDOMQuoteRemover.removeQuotes(from: html)
        let pass2 = EmailDOMQuoteRemover.removeQuotes(from: pass1)
        XCTAssertEqual(plainText(pass1), plainText(pass2))
    }
}
