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

    func testRecoverHTMLContent_postsContentSourceDidChangeNotification() async {
        let messageId = "html-recovery-source-change-\(UUID().uuidString)"
        let attachmentId = "html-body-\(UUID().uuidString)"
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>AMNH_SOURCE_CHANGE_TOKEN</h1>
          <p>Recovered newsletter body.</p>
        </body>
        </html>
        """
        let expectedSourceSignature = CanonicalEmailContent(
            html: html,
            plainText: nil,
            sourceKind: .recoveredHTML,
            sourceLocation: .recoveredHTML
        ).sourceSignature

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

        let sourceChangeExpectation = expectation(description: "Recovered HTML source change notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: HTMLContentLoader.contentSourceDidChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.userInfo?[HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey] as? String == messageId else {
                return
            }
            XCTAssertEqual(
                notification.userInfo?[HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey] as? String,
                expectedSourceSignature
            )
            XCTAssertTrue(Thread.isMainThread)
            sourceChangeExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, html)
        await fulfillment(of: [sourceChangeExpectation], timeout: 1.0)
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

    func testRecoverHTMLContent_prefersHTMLMimeBodyOverLargerEmbeddedRawSource() async {
        let messageId = "html-recovery-html-body-over-embedded-\(UUID().uuidString)"
        let bodyHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_ACTUAL_MESSAGE_BODY</h1>
          <p>The opened email body should be recovered.</p>
        </body>
        </html>
        """
        let embeddedHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_EMBEDDED_FORWARDED_BODY</h1>
          <img src="https://example.com/forwarded.png" alt="forwarded">
          <table><tr><td>Forwarded content with richer markup.</td></tr></table>
          \(String(repeating: "<p>Forwarded source text that should not replace the opened message.</p>\n", count: 20))
        </body>
        </html>
        """
        let rawSource = """
        Content-Type: multipart/alternative; boundary="forwarded-boundary-123"
        MIME-Version: 1.0

        --forwarded-boundary-123
        Content-Type: text/plain; charset="utf-8"

        Forwarded source text.

        --forwarded-boundary-123
        Content-Type: text/html; charset="utf-8"

        \(embeddedHTML)

        --forwarded-boundary-123--
        """

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLCandidatesMessage(
            id: messageId,
            htmlParts: [
                inlineHTMLPart(partId: "0.0", html: bodyHTML),
                inlineRawSourcePart(partId: "0.1", rawSource: rawSource)
            ]
        )

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, bodyHTML)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("HTML_TOKEN_ACTUAL_MESSAGE_BODY") == true)
        XCTAssertFalse(contentHandler.loadHTML(for: messageId)?.contains("HTML_TOKEN_EMBEDDED_FORWARDED_BODY") == true)
    }

    func testRecoverHTMLContent_doesNotFetchAttachmentBackedRawSourceWhenHTMLMimeBodyIsMeaningful() async {
        let messageId = "html-recovery-skip-raw-attachment-\(UUID().uuidString)"
        let rawSourceAttachmentId = "raw-source-\(UUID().uuidString)"
        let bodyHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_ATTACHMENT_FETCH_NOT_NEEDED</h1>
          <p>The opened email body should be recovered without fetching raw alternatives.</p>
        </body>
        </html>
        """
        let rawSource = """
        Content-Type: multipart/alternative; boundary="raw-source-boundary-123"
        MIME-Version: 1.0

        --raw-source-boundary-123
        Content-Type: text/plain; charset="utf-8"

        Raw source fallback text.

        --raw-source-boundary-123
        Content-Type: text/html; charset="utf-8"

        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_RAW_ATTACHMENT_SHOULD_NOT_FETCH</h1>
          <p>This attachment-backed raw source is only a fallback.</p>
        </body>
        </html>

        --raw-source-boundary-123--
        """

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLCandidatesMessage(
            id: messageId,
            htmlParts: [
                inlineHTMLPart(partId: "0.0", html: bodyHTML),
                attachmentPart(partId: "0.1", mimeType: "text/plain", attachmentId: rawSourceAttachmentId)
            ]
        )
        mockAPIClient.attachmentResponses["\(messageId):\(rawSourceAttachmentId)"] = Data(rawSource.utf8)

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, bodyHTML)
        XCTAssertEqual(mockAPIClient.getAttachmentCallCount, 0)
        XCTAssertFalse(contentHandler.loadHTML(for: messageId)?.contains("HTML_TOKEN_RAW_ATTACHMENT_SHOULD_NOT_FETCH") == true)
    }

    func testRecoverHTMLContent_choosesMeaningfulHTMLCandidateAfterEmptyOrHiddenParts() async {
        let messageId = "html-recovery-multiple-candidates-\(UUID().uuidString)"
        let emptyHTML = "   "
        let hiddenOnlyHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <div style="display:none">Hidden preheader only</div>
        </body>
        </html>
        """
        let meaningfulHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_MEANINGFUL_CANDIDATE</h1>
          <p>The visible newsletter body should win.</p>
        </body>
        </html>
        """

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLCandidatesMessage(
            id: messageId,
            htmlParts: [
                inlineHTMLPart(partId: "0.0", html: emptyHTML),
                inlineHTMLPart(partId: "0.1", html: hiddenOnlyHTML),
                inlineHTMLPart(partId: "0.2", html: meaningfulHTML)
            ]
        )

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, meaningfulHTML)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("HTML_TOKEN_MEANINGFUL_CANDIDATE") == true)
    }

    func testRecoverHTMLContent_skipsHTMLFileAttachmentsWhenScoringCandidates() async {
        let messageId = "html-recovery-html-attachment-\(UUID().uuidString)"
        let attachmentId = "html-file-attachment-\(UUID().uuidString)"
        let bodyHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_MESSAGE_BODY</h1>
          <p>The message body should be recovered.</p>
        </body>
        </html>
        """
        let attachmentHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_ATTACHED_DOCUMENT</h1>
          <img src="https://example.com/report.png" alt="report">
          <table><tr><td>Attached document with much more visible text and richer markup.</td></tr></table>
          <p>This attachment must not replace the original email body during recovery.</p>
        </body>
        </html>
        """

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLCandidatesMessage(
            id: messageId,
            htmlParts: [
                inlineHTMLPart(partId: "0.0", html: bodyHTML),
                htmlFileAttachmentPart(partId: "0.1", attachmentId: attachmentId)
            ]
        )
        mockAPIClient.attachmentResponses["\(messageId):\(attachmentId)"] = Data(attachmentHTML.utf8)

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, bodyHTML)
        XCTAssertEqual(mockAPIClient.getAttachmentCallCount, 0)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("HTML_TOKEN_MESSAGE_BODY") == true)
    }

    func testRecoverHTMLContent_choosesLargeAttachmentBackedHTMLCandidate() async {
        let messageId = "html-recovery-large-candidate-\(UUID().uuidString)"
        let attachmentId = "large-html-body-\(UUID().uuidString)"
        let hiddenOnlyHTML = """
        <html><body><div hidden>Hidden first candidate</div></body></html>
        """
        let meaningfulHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_LARGE_ATTACHMENT_CANDIDATE</h1>
          <p>The large attachment-backed HTML body should be recovered.</p>
        </body>
        </html>
        """

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLCandidatesMessage(
            id: messageId,
            htmlParts: [
                inlineHTMLPart(partId: "0.0", html: hiddenOnlyHTML),
                attachmentHTMLPart(partId: "0.1", attachmentId: attachmentId)
            ]
        )
        mockAPIClient.attachmentResponses["\(messageId):\(attachmentId)"] = Data(meaningfulHTML.utf8)

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, meaningfulHTML)
        XCTAssertEqual(mockAPIClient.getAttachmentCallCount, 1)
        XCTAssertTrue(contentHandler.loadHTML(for: messageId)?.contains("HTML_TOKEN_LARGE_ATTACHMENT_CANDIDATE") == true)
    }

    func testRecoverHTMLContent_doesNotFetchNonTextAttachmentsWhileCollectingCandidates() async {
        let messageId = "html-recovery-skip-image-attachment-\(UUID().uuidString)"
        let imageAttachmentId = "image-attachment-\(UUID().uuidString)"
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>HTML_TOKEN_SKIP_IMAGE_ATTACHMENT</h1>
          <p>The image attachment should not be fetched during HTML recovery.</p>
        </body>
        </html>
        """

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLCandidatesMessage(
            id: messageId,
            htmlParts: [
                inlineHTMLPart(partId: "0.0", html: html),
                attachmentPart(partId: "0.1", mimeType: "image/png", attachmentId: imageAttachmentId)
            ]
        )
        mockAPIClient.attachmentResponses["\(messageId):\(imageAttachmentId)"] = Data([0x89, 0x50, 0x4E, 0x47])

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, html)
        XCTAssertEqual(mockAPIClient.getAttachmentCallCount, 0)
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

    func testRecoverHTMLContent_cachesNoHTMLMissesWithinTTL() async {
        let messageId = "html-recovery-no-html-\(UUID().uuidString)"
        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makePlainTextOnlyMessage(id: messageId)

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler,
            noHTMLMissCacheTTL: 300
        )

        let firstRecovery = await service.recoverHTMLContent(messageId: messageId)
        let secondRecovery = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertNil(firstRecovery)
        XCTAssertNil(secondRecovery)
        XCTAssertEqual(mockAPIClient.getMessageCallCount, 1)
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

    private func makePlainTextOnlyMessage(id: String) -> GmailMessage {
        let plainText = "Plain text body"

        return GmailMessage(
            id: id,
            threadId: "\(id)-thread",
            labelIds: ["INBOX"],
            snippet: plainText,
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
                    size: plainText.count,
                    data: plainText.data(using: .utf8)?.base64EncodedString(),
                    attachmentId: nil
                ),
                parts: nil
            ),
            sizeEstimate: plainText.count
        )
    }

    private func makeHTMLCandidatesMessage(id: String, htmlParts: [MessagePart]) -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "\(id)-thread",
            labelIds: ["INBOX"],
            snippet: "Multiple HTML candidates",
            historyId: "12345",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "0",
                mimeType: "multipart/alternative",
                filename: nil,
                headers: nil,
                body: nil,
                parts: htmlParts
            ),
            sizeEstimate: htmlParts.reduce(0) { total, part in
                total + (part.body?.size ?? 0)
            }
        )
    }

    private func inlineHTMLPart(partId: String, html: String) -> MessagePart {
        MessagePart(
            partId: partId,
            mimeType: "text/html",
            filename: nil,
            headers: nil,
            body: MessageBody(
                size: html.count,
                data: Data(html.utf8).base64EncodedString(),
                attachmentId: nil
            ),
            parts: nil
        )
    }

    private func inlineRawSourcePart(
        partId: String,
        mimeType: String = "message/rfc822",
        rawSource: String
    ) -> MessagePart {
        MessagePart(
            partId: partId,
            mimeType: mimeType,
            filename: nil,
            headers: [
                MessageHeader(name: "Content-Type", value: mimeType)
            ],
            body: MessageBody(
                size: rawSource.count,
                data: Data(rawSource.utf8).base64EncodedString(),
                attachmentId: nil
            ),
            parts: nil
        )
    }

    private func attachmentHTMLPart(partId: String, attachmentId: String) -> MessagePart {
        attachmentPart(partId: partId, mimeType: "text/html", attachmentId: attachmentId)
    }

    private func htmlFileAttachmentPart(partId: String, attachmentId: String) -> MessagePart {
        MessagePart(
            partId: partId,
            mimeType: "text/html",
            filename: "attached-document.html",
            headers: [
                MessageHeader(name: "Content-Disposition", value: "attachment; filename=\"attached-document.html\"")
            ],
            body: MessageBody(
                size: 0,
                data: nil,
                attachmentId: attachmentId
            ),
            parts: nil
        )
    }

    private func attachmentPart(partId: String, mimeType: String, attachmentId: String) -> MessagePart {
        MessagePart(
            partId: partId,
            mimeType: mimeType,
            filename: nil,
            headers: nil,
            body: MessageBody(
                size: 0,
                data: nil,
                attachmentId: attachmentId
            ),
            parts: nil
        )
    }
}
