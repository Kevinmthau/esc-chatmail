import XCTest
@testable import esc_chatmail

final class MimeBuilderReplyTests: XCTestCase {
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
}
