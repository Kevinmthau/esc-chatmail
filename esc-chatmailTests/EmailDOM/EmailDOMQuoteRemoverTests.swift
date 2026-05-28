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

    func testRemoveQuotes_strongFromSubjectHeaderWithoutReferenceContainer_truncates() {
        let html = """
        <div>Current reply.</div>
        <div><strong>From:</strong> Alice Example</div>
        <div><strong>Sent:</strong> Monday, January 1, 2026 9:00 AM</div>
        <div><strong>To:</strong> Bob Example</div>
        <div><strong>Subject:</strong> Re: Planning</div>
        <div>Older thread should be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("Alice Example"))
        XCTAssertFalse(text.contains("Older thread should be hidden."))
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

    func testRemoveQuotes_onDateWroteAfterLineBreakInsideTextNode_removesFollowingNodes() {
        let html = """
        <p>Hello.
        On Mon, Jan 15, 2024 at 10:30 AM John wrote:<span>inline quote</span></p>
        <p>Older message</p>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Hello."))
        XCTAssertFalse(text.contains("John wrote"))
        XCTAssertFalse(text.contains("inline quote"))
        XCTAssertFalse(text.contains("Older message"))
    }

    func testRemoveQuotes_inlineSplitOnDateWrote_truncatesAtMarker() {
        let html = """
        <div>Current reply.</div>
        <div>On Jan 1 <b>John</b> wrote:</div>
        <div>Old thread should be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("John"))
        XCTAssertFalse(text.contains("Old thread should be hidden."))
    }

    func testRemoveQuotes_inlineSplitOnDateWroteAfterBR_truncatesAtMarker() {
        let html = """
        <div>Current reply.<br>On Jan 1 <b>John</b> wrote:</div>
        <div>Old thread should be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("John"))
        XCTAssertFalse(text.contains("Old thread should be hidden."))
    }

    func testRemoveQuotes_midSentenceOnWrote_preservesCurrentContent() {
        let html = """
        <p>Following up on what John wrote: I agree with the plan.</p>
        <p>Current message should remain visible.</p>
        <p>On Mon, Jan 15, 2024 at 10:30 AM John wrote:</p>
        <p>Older message</p>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Following up on what John wrote: I agree with the plan."))
        XCTAssertTrue(text.contains("Current message should remain visible."))
        XCTAssertFalse(text.contains("Older message"))
    }

    func testRemoveQuotes_inlineSplitMarkerBeforeSingleNodeMarker_truncatesAtEarlierSplitMarker() {
        let html = """
        <div>Current reply.</div>
        <div>On Jan 1 <b>John</b> wrote:</div>
        <div>Nested reply should be hidden.</div>
        <div>On Dec 31 Jane wrote:</div>
        <div>Older thread should also be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("On Jan 1"))
        XCTAssertFalse(text.contains("John"))
        XCTAssertFalse(text.contains("Nested reply should be hidden."))
        XCTAssertFalse(text.contains("Jane"))
        XCTAssertFalse(text.contains("Older thread should also be hidden."))
    }

    func testRemoveQuotes_inlineSplitOnDateWrote_preservesPrefixBeforeMarker() {
        let html = """
        <p>Hello.
        On Jan 1 <b>John</b> wrote:<span>inline quote</span></p>
        <p>Older message</p>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertEqual(text, "Hello.")
        XCTAssertFalse(text.contains("John"))
        XCTAssertFalse(text.contains("inline quote"))
        XCTAssertFalse(text.contains("Older message"))
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

    func testRemoveQuotes_signatureMode_preservesCombinedMultiWordSignOffAndName() {
        let html = """
        <p>Body.</p>
        <div class="gmail_signature">
            <div>Best regards John Ronald Reuel Tolkien</div>
            <div>Professor of Anglo-Saxon</div>
            <div>tolkien@example.com</div>
        </div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))
        XCTAssertTrue(text.contains("Body."))
        XCTAssertTrue(text.contains("Best regards John Ronald Reuel Tolkien"))
        XCTAssertFalse(text.contains("Professor of Anglo-Saxon"))
        XCTAssertFalse(text.contains("tolkien@example.com"))
    }

    func testRemoveQuotes_signatureMode_preservesSignOffNameLineBreakAndTail() {
        let html = """
        <div>Body.</div>
        <div class="gmail_signature">
            <div>
                <div>Best,<br>Janet</div>
                <div><table><tr><td>617.221.4242</td></tr></table></div>
            </div>
        </div>
        <div>P.S. one more thing.</div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))
        XCTAssertEqual(text, "Body.\n\nBest,\nJanet\n\nP.S. one more thing.")
        XCTAssertFalse(text.contains("617.221.4242"))
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

    func testRemoveQuotes_fragmentWithHeaderElement_returnsFragmentNotWrappedDocument() {
        let html = """
        <header><p>Body.</p></header>
        <div class="gmail_quote"><p>Quote</p></div>
        """

        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""

        XCTAssertFalse(result.lowercased().contains("<html"),
                       "Fragment input should not gain <html> wrapper, got: \(result)")
        XCTAssertFalse(result.lowercased().contains("<body"),
                       "Fragment input should not gain <body> wrapper, got: \(result)")
        XCTAssertTrue(result.contains("<header>"))
        XCTAssertTrue(result.contains("<p>Body.</p>"))
        XCTAssertFalse(result.contains("Quote"))
    }

    func testRemoveQuotes_standaloneTableRowFragmentPreservesLayout() {
        let html = "<tr><td>Visible body.</td></tr>"

        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        let lowercasedResult = result.lowercased()

        XCTAssertFalse(lowercasedResult.contains("<html"),
                       "Fragment input should not gain <html> wrapper, got: \(result)")
        XCTAssertFalse(lowercasedResult.contains("<body"),
                       "Fragment input should not gain <body> wrapper, got: \(result)")
        XCTAssertTrue(lowercasedResult.contains("<tr"))
        XCTAssertTrue(result.contains("<td>Visible body.</td>"))
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

    func testRemoveQuotes_lateBodyDocumentPreservesBodyAttributes() throws {
        let preheader = String(repeating: "Hidden preheader text. ", count: 120)
        let html = #"""
        <!-- \#(preheader) -->
        <body class="promo" style="margin:0" bgcolor="#f4f4f4">
          <p>Body.</p>
          <div class="gmail_quote"><p>Quote</p></div>
        </body>
        """#
        let bodyRange = try XCTUnwrap(html.range(of: "<body"))
        XCTAssertGreaterThan(html.distance(from: html.startIndex, to: bodyRange.lowerBound), 2048)

        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        let lowercasedResult = result.lowercased()

        XCTAssertTrue(lowercasedResult.contains("<body"))
        XCTAssertTrue(result.contains(#"class="promo""#))
        XCTAssertTrue(result.contains(#"style="margin:0""#))
        XCTAssertTrue(result.contains("bgcolor=\"#f4f4f4\""))
        XCTAssertTrue(result.contains("<p>Body.</p>"))
        XCTAssertFalse(result.contains("Quote"))
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
