import XCTest
import SwiftSoup
import WebKit
@testable import esc_chatmail

final class MimeBuilderReplyTests: XCTestCase {
    func testReplyLinksPreserveQueryParametersAndExcludeTrailingPunctuation() throws {
        let url = "https://example.com/search?first=one&second=two#results"
        let html = MimeBuilder.formatReplyHTMLBody(
            body: "See \(url). Then (https://en.wikipedia.org/wiki/Swift_(programming_language)).",
            originalMessage: nil
        )
        let document = try SwiftSoup.parse(html)
        let links = try document.select("a")

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(try links.get(0).attr("href"), url)
        XCTAssertEqual(try links.get(0).text(), url)
        XCTAssertEqual(
            try links.get(1).attr("href"),
            "https://en.wikipedia.org/wiki/Swift_(programming_language)"
        )
        XCTAssertEqual(
            try document.body()?.text(),
            "See \(url). Then (https://en.wikipedia.org/wiki/Swift_(programming_language))."
        )
    }

    func testReplyLinksEscapeTextAndAttributesWithoutAddingMarkup() throws {
        let body = "<strong>Read</strong> https://example.com/?a=1&b=2&name=O'Reilly and www.example.org."
        let html = MimeBuilder.formatReplyHTMLBody(body: body, originalMessage: nil)
        let document = try SwiftSoup.parse(html)
        let links = try document.select("a")

        XCTAssertTrue(try document.select("strong").isEmpty())
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(try links.get(0).attr("href"), "https://example.com/?a=1&b=2&name=O'Reilly")
        XCTAssertEqual(try links.get(1).attr("href"), "https://www.example.org")
        XCTAssertEqual(try document.body()?.text(), body)
    }

    func testSubjectlessRepliesKeepAnEmptySubjectWithAndWithoutAttachments() throws {
        let attachment = AttachmentData(data: Data("file".utf8), filename: "note.txt", mimeType: "text/plain")
        for attachments in [[], [attachment]] {
            let data = MimeBuilder.buildReply(
                to: ["friend@example.com"],
                from: "me@example.com",
                body: "Thanks!",
                subject: "",
                inReplyTo: "<original@example.com>",
                references: ["<original@example.com>"],
                attachments: attachments
            )
            XCTAssertEqual(try subjectHeader(in: data), "Subject: ")
        }
    }

    func testNewMessagesKeepDefaultSubjectForNilAndEmptySubjects() throws {
        let attachment = AttachmentData(data: Data("file".utf8), filename: "note.txt", mimeType: "text/plain")
        for subject: String? in [nil, ""] {
            for html: String? in [nil, "<p>Hello</p>"] {
                for attachments in [[], [attachment]] {
                    let data = MimeBuilder.buildNew(
                        to: ["friend@example.com"],
                        from: "me@example.com",
                        body: "Hello",
                        htmlBody: html,
                        subject: subject,
                        attachments: attachments
                    )
                    XCTAssertEqual(try subjectHeader(in: data), "Subject: (No Subject)")
                }
            }
        }
    }

    func testPlainTextMIMEFallbackPreservesAnExplicitEmptyReplySubject() throws {
        let attachment = AttachmentData(data: Data("file".utf8), filename: "note.txt", mimeType: "text/plain")
        for attachments in [[], [attachment]] {
            let data = MimeBuilder.buildAlternativeMessage(
                to: ["friend@example.com"],
                from: "me@example.com",
                fromName: nil,
                body: "Thanks!",
                htmlBody: "<img src=\"cid:invalid id\">",
                subject: "",
                inReplyTo: "<original@example.com>",
                references: [],
                attachments: attachments,
                inlineAttachments: [
                    InlineAttachmentData(data: Data(), contentId: "invalid id", filename: "photo.png", mimeType: "image/png")
                ],
                preserveEmptySubject: true
            )
            XCTAssertEqual(try subjectHeader(in: data), "Subject: ")
        }
    }

    @MainActor
    func testAuthoredReplyRemainsReadableWhenQuotedBodyResetsInheritedTypography() async throws {
        let original = QuotedMessage(
            senderName: "Friend",
            senderEmail: "friend@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            body: "Original content",
            originalHTML: """
            <html><body style="font-size: 0; line-height: 0; color: white; background-color: white; text-align: right;">
            <div class="original-content" style="font-size: 24px; color: rgb(200, 30, 40);">Original content</div>
            </body></html>
            """
        )
        let html = MimeBuilder.formatReplyHTMLBody(body: "My readable response", originalMessage: original)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        webView.loadHTMLString(html, baseURL: nil)

        var styles: [String: String]?
        for _ in 0..<100 where styles == nil {
            styles = try? await webView.evaluateJavaScript("""
                (() => {
                    const reply = document.body?.firstElementChild;
                    const original = document.querySelector('.original-content');
                    if (!reply?.textContent.includes('My readable response') || !original) return null;
                    const text = reply.querySelector('div, p') || reply;
                    const style = getComputedStyle(text);
                    const originalStyle = getComputedStyle(original);
                    return {
                        fontSize: style.fontSize,
                        lineHeight: style.lineHeight,
                        color: style.color,
                        textAlign: style.textAlign,
                        originalFontSize: originalStyle.fontSize,
                        originalColor: originalStyle.color
                    };
                })();
                """) as? [String: String]
            if styles == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let rendered = try XCTUnwrap(styles, "Timed out loading the reply HTML")
        XCTAssertEqual(rendered["fontSize"], "14px")
        XCTAssertEqual(rendered["lineHeight"], "21px")
        XCTAssertEqual(rendered["color"], "rgb(34, 34, 34)")
        XCTAssertEqual(rendered["textAlign"], "left")
        XCTAssertEqual(rendered["originalFontSize"], "24px")
        XCTAssertEqual(rendered["originalColor"], "rgb(200, 30, 40)")
    }

    private func subjectHeader(in data: Data) throws -> String {
        let mime = try XCTUnwrap(String(data: data, encoding: .utf8))
        return try XCTUnwrap(mime.components(separatedBy: "\r\n").first { $0.hasPrefix("Subject:") })
    }

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
