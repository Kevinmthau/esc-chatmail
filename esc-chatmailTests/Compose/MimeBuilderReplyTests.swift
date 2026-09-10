import XCTest
@testable import esc_chatmail

final class MimeBuilderReplyTests: XCTestCase {
    func testResolvedDeferredHTMLIsSanitizedBeforeReplyMIMEFormatting() async throws {
        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimeBuilderReplyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: messagesDirectory) }
        let contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        let contentLoader = HTMLContentLoader(
            contentHandler: contentHandler,
            sanitizer: .shared
        )
        let messageID = "deferred-mime-message"
        XCTAssertNotNil(
            contentHandler.saveHTML(
                """
                <html><body>
                <script>UNSAFE_SCRIPT_TOKEN</script>
                <p>SAFE_ORIGINAL_HTML_TOKEN</p>
                </body></html>
                """,
                for: messageID
            )
        )
        let originalMessage = QuotedMessage(
            senderName: "Friend",
            senderEmail: "friend@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            body: "Original fallback body",
            deferredOriginalHTML: DeferredReplyQuotedHTML(
                source: ReplyQuotedHTMLSource(
                    messageId: messageID,
                    bodyStorageURI: nil,
                    bodyText: "Original fallback body",
                    senderEmail: "friend@example.com",
                    subject: "Original subject"
                ),
                resolver: ReplyQuotedHTMLResolver(contentLoader: contentLoader)
            )
        )

        let resolvedOriginal = await originalMessage.resolvingOriginalHTML()
        let result = MimeBuilder.formatReplyHTMLBody(
            body: "Thanks!",
            originalMessage: resolvedOriginal
        )

        XCTAssertTrue(result.contains("SAFE_ORIGINAL_HTML_TOKEN"))
        XCTAssertFalse(result.contains("UNSAFE_SCRIPT_TOKEN"))
    }

    func testFormatReplyHTMLBody_withOriginalHTMLPreservesOriginalDocumentStyling() {
        let originalMessage = QuotedMessage(
            senderName: "Friend",
            senderEmail: "friend@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            body: "Original fallback body",
            originalHTML: """
            <!DOCTYPE html>
            <html>
            <head>
            <style>.original-body { color: red; }</style>
            </head>
            <body>
            <div class="original-body">Original <strong>HTML</strong></div>
            </body>
            </html>
            """
        )

        let result = MimeBuilder.formatReplyHTMLBody(body: "Thanks!", originalMessage: originalMessage)

        XCTAssertTrue(result.contains(".original-body { color: red; }"))
        XCTAssertTrue(result.contains("Thanks!"))
        XCTAssertTrue(result.contains("gmail_quote gmail_quote_container"))
        XCTAssertTrue(result.contains("class=\"gmail_attr\""))
        XCTAssertTrue(result.contains("blockquote class=\"gmail_quote\""))
        XCTAssertTrue(result.contains("<div class=\"original-body\">Original <strong>HTML</strong></div>"))
    }

    func testFormatReplyHTMLBody_withOriginalHTMLStripsExistingQuotedHistoryAndSignatures() {
        let originalMessage = QuotedMessage(
            senderName: "Friend",
            senderEmail: "friend@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            body: "Original fallback body",
            originalHTML: """
            <html>
            <body>
            <div class="latest-message">Latest update</div>
            <div class="gmail_quote">
              <div class="gmail_attr">On Jan 1, 2026, Old Friend wrote:</div>
              <blockquote>Older quoted thread</blockquote>
            </div>
            <div class="signature">Signature block</div>
            </body>
            </html>
            """
        )

        let result = MimeBuilder.formatReplyHTMLBody(body: "Thanks!", originalMessage: originalMessage)

        XCTAssertTrue(result.contains("Latest update"))
        XCTAssertTrue(result.contains("gmail_quote gmail_quote_container"))
        XCTAssertFalse(result.contains("Older quoted thread"))
        XCTAssertFalse(result.contains("Signature block"))
    }

    func testFormatReplyHTMLBody_withoutOriginalHTMLFallsBackToPlainTextQuote() {
        let originalMessage = QuotedMessage(
            senderName: "Friend",
            senderEmail: "friend@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            body: "Original body"
        )

        let result = MimeBuilder.formatReplyHTMLBody(body: "Thanks!", originalMessage: originalMessage)

        XCTAssertTrue(result.contains("Thanks!"))
        XCTAssertTrue(result.contains("Friend wrote:"))
        XCTAssertTrue(result.contains("<blockquote style=\"margin: 0; padding: 0 0 0 12px; border-left: 2px solid #dadce0; color: #555;\">"))
        XCTAssertTrue(result.contains("Original body"))
        XCTAssertFalse(result.contains("gmail_quote gmail_quote_container"))
    }

    func testFormatReplyHTMLBody_withCIDOriginalHTMLFallsBackToPlainTextQuote() {
        let originalMessage = QuotedMessage(
            senderName: "Friend",
            senderEmail: "friend@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            body: "Original body",
            originalHTML: """
            <html>
            <body>
            <p><img src="cid:logo@example.com" alt="Logo"></p>
            <p>Original HTML body</p>
            </body>
            </html>
            """
        )

        let result = MimeBuilder.formatReplyHTMLBody(body: "Thanks!", originalMessage: originalMessage)

        XCTAssertTrue(result.contains("Thanks!"))
        XCTAssertTrue(result.contains("Original body"))
        XCTAssertFalse(result.contains("cid:logo@example.com"))
        XCTAssertFalse(result.contains("gmail_quote gmail_quote_container"))
    }
}
