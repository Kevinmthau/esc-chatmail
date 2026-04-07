import XCTest
@testable import esc_chatmail

final class HTMLContentRecoveryServiceTests: XCTestCase {
    func testRecoverHTMLContent_concurrentCallsShareSingleRecoveryAndReturnHTML() async {
        let messageId = "html-recovery-concurrent-\(UUID().uuidString)"
        let attachmentId = "html-body-\(UUID().uuidString)"
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>AMNH_HTML_TOKEN</h1>
          <p>Recovered newsletter body.</p>
        </body>
        </html>
        """

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.artificialDelay = 0.05
        mockAPIClient.getMessageResponses[messageId] = makeHTMLAttachmentMessage(
            id: messageId,
            attachmentId: attachmentId
        )
        mockAPIClient.attachmentResponses["\(messageId):\(attachmentId)"] = Data(html.utf8)

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        async let first = service.recoverHTMLContent(messageId: messageId)
        async let second = service.recoverHTMLContent(messageId: messageId)

        let firstHTML = await first
        let secondHTML = await second

        XCTAssertEqual(firstHTML, html)
        XCTAssertEqual(secondHTML, html)
        XCTAssertEqual(mockAPIClient.getMessageCallCount, 1)
        XCTAssertEqual(mockAPIClient.getAttachmentCallCount, 1)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("AMNH_HTML_TOKEN") == true)
    }

    func testRecoverHTMLContent_textBodyContainingMimeOnlyRawSource_extractsEmbeddedHTML() async {
        let messageId = "html-recovery-mime-only-\(UUID().uuidString)"
        let rawSource = """
        Content-Type: multipart/alternative; boundary="newsletter-boundary-123"
        MIME-Version: 1.0

        --newsletter-boundary-123
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        Example Museum
        Tickets are now on sale for the 2026 Film Festival
        View in Browser

        --newsletter-boundary-123
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_MIME_ONLY_RECOVERY</h1>
          <p>Tickets are now on sale for the 2026 Film Festival</p>
        </body>
        </html>

        --newsletter-boundary-123--
        """

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = GmailMessage(
            id: messageId,
            threadId: "\(messageId)-thread",
            labelIds: ["INBOX"],
            snippet: "Tickets are now on sale",
            historyId: "12345",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "text/plain",
                filename: nil,
                headers: [
                    MessageHeader(name: "Content-Type", value: "text/plain; charset=utf-8")
                ],
                body: MessageBody(
                    size: rawSource.count,
                    data: rawSource.data(using: .utf8)?.base64EncodedString(),
                    attachmentId: nil
                ),
                parts: nil
            ),
            sizeEstimate: rawSource.count
        )

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertTrue(recoveredHTML?.contains("HTML_TOKEN_MIME_ONLY_RECOVERY") == true)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("HTML_TOKEN_MIME_ONLY_RECOVERY") == true)
    }

    func testRecoverHTMLContent_invalidatesProcessedTextCacheForRecoveredMessage() async {
        let messageId = "html-recovery-cache-invalidation-\(UUID().uuidString)"
        let attachmentId = "html-body-\(UUID().uuidString)"
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>AMNH_INVALIDATION_TOKEN</h1>
          <p>Recovered newsletter body.</p>
        </body>
        </html>
        """

        await ProcessedTextCache.shared.set(
            messageId: messageId,
            plainText: "Stale fallback",
            hasRichContent: false
        )

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLAttachmentMessage(
            id: messageId,
            attachmentId: attachmentId
        )
        mockAPIClient.attachmentResponses["\(messageId):\(attachmentId)"] = Data(html.utf8)

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, html)
        let cached = await ProcessedTextCache.shared.get(messageId: messageId)
        XCTAssertNil(cached)
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
    }

    private func makeHTMLAttachmentMessage(id: String, attachmentId: String) -> GmailMessage {
        let plainText = "Fallback plain text body"

        return GmailMessage(
            id: id,
            threadId: "\(id)-thread",
            labelIds: ["INBOX"],
            snippet: plainText,
            historyId: "12345",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "multipart/alternative",
                filename: nil,
                headers: [
                    MessageHeader(name: "Subject", value: "Recovered HTML test"),
                    MessageHeader(name: "From", value: "newsletter@example.com"),
                    MessageHeader(name: "To", value: "person@example.com")
                ],
                body: nil,
                parts: [
                    MessagePart(
                        partId: "0.0",
                        mimeType: "text/plain",
                        filename: nil,
                        headers: nil,
                        body: MessageBody(
                            size: plainText.count,
                            data: plainText.data(using: .utf8)?.base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    ),
                    MessagePart(
                        partId: "0.1",
                        mimeType: "text/html",
                        filename: nil,
                        headers: nil,
                        body: MessageBody(
                            size: 0,
                            data: nil,
                            attachmentId: attachmentId
                        ),
                        parts: nil
                    )
                ]
            ),
            sizeEstimate: plainText.count
        )
    }
}
