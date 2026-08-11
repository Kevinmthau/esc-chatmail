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

    // Guards the EVICTION half of the scoped-invalidation change in
    // `HTMLContentRecoveryService.performRecoveryToCompletion`: recovery passes
    // `invalidatesRenderedMessage: false` to ProcessedTextCache because the
    // scoped `HTMLContentLoader.shared.invalidateContent(messageId:accountContext:)`
    // hop is what evicts RenderedMessageCache. This test fails if that hop is
    // dropped, so a future change cannot silently stop evicting the stale
    // rendered chat-bubble artifact.
    //
    // HONEST SCOPE — this is NOT a revert-check for the account-SCOPING half.
    // Verified empirically: reverting both hunks of that fix (back to the
    // unscoped `invalidateContent(messageId:)` + `invalidate(messageId:)`
    // pair, with no pre-write capture) leaves this test GREEN, because the
    // unscoped calls evict the same entry in a single-account test.
    // The scoping only diverges when an account transition lands between the
    // capture and the invalidation — a window bounded by two `await`s inside
    // this actor with no injection point, since the method reaches
    // `HTMLContentLoader.shared`/`ProcessedTextCache.shared` directly rather
    // than through the injectable `contentHandler`. Covering it needs a
    // production seam; until then that half rests on parity with the reviewed
    // implementation in `CanonicalEmailContentLoader.loadCanonicalEmailContent`.
    // (The companion test in HTMLContentAccountBoundaryTests does pin the
    // separable half: `invalidatesRenderedMessage: false` really does suppress
    // ProcessedTextCache's own unscoped rendered hop.)
    func testRecoverHTMLContent_stillEvictsRenderedMessageArtifactsAfterScopedInvalidation() async {
        let messageId = "html-recovery-rendered-eviction-\(UUID().uuidString)"
        let attachmentId = "html-body-\(UUID().uuidString)"
        let staleSourceSignature = "stale-rendered-source-\(UUID().uuidString)"
        let variantKey: RenderedMessageVariantKey = "recovery-rendered-eviction"
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>AMNH_RENDERED_EVICTION_TOKEN</h1>
          <p>Recovered newsletter body.</p>
        </body>
        </html>
        """

        await RenderedMessageCache.shared.storeChatBubbleText(
            RenderedMessageChatBubbleText(plainText: "Stale bubble", hasRichContent: false),
            messageId: messageId,
            sourceSignature: staleSourceSignature,
            variantKey: variantKey
        )
        await ProcessedTextCache.shared.set(
            messageId: messageId,
            plainText: "Stale fallback",
            hasRichContent: false
        )

        let seededBubble = await RenderedMessageCache.shared.cachedChatBubbleText(
            messageId: messageId,
            sourceSignature: staleSourceSignature,
            variantKey: variantKey
        )
        XCTAssertNotNil(seededBubble, "Precondition: the stale rendered artifact must be cached before recovery")

        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLAttachmentMessage(
            id: messageId,
            attachmentId: attachmentId
        )
        mockAPIClient.attachmentResponses["\(messageId):\(attachmentId)"] = Data(html.utf8)

        // The default Messages directory shares an account boundary with
        // `HTMLContentLoader.shared.contentHandler`, so the invalidation context
        // captured inside recovery stays valid for this handler's write.
        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveredHTML = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recoveredHTML, html)

        let evictedBubble = await RenderedMessageCache.shared.cachedChatBubbleText(
            messageId: messageId,
            sourceSignature: staleSourceSignature,
            variantKey: variantKey
        )
        XCTAssertNil(
            evictedBubble,
            "The scoped invalidateContent hop must still evict rendered artifacts after recovery rewrites the HTML"
        )

        let cachedProcessedText = await ProcessedTextCache.shared.get(messageId: messageId)
        XCTAssertNil(cachedProcessedText)

        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        await RenderedMessageCache.shared.invalidate(messageId: messageId)
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

    func testRecoverHTMLContent_timesOutSlowFetchThenAllowsFreshRetry() async {
        let messageId = "html-recovery-timeout-\(UUID().uuidString)"
        let attachmentId = "html-body-\(UUID().uuidString)"
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>RECOVERY_TIMEOUT_TOKEN</h1>
          <p>Recovered after the network recovers.</p>
        </body>
        </html>
        """

        let mockAPIClient = MockGmailAPIClient()
        // Far longer than the recovery deadline below, so the first fetch is abandoned.
        mockAPIClient.artificialDelay = 5.0
        mockAPIClient.getMessageResponses[messageId] = makeHTMLAttachmentMessage(
            id: messageId,
            attachmentId: attachmentId
        )
        mockAPIClient.attachmentResponses["\(messageId):\(attachmentId)"] = Data(html.utf8)

        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageId) }

        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler,
            recoveryNetworkTimeout: 0.2
        )

        let start = Date()
        let timedOut = await service.recoverHTMLContent(messageId: messageId)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(timedOut, "a fetch slower than the deadline must surface as a failure, not hang")
        XCTAssertLessThan(elapsed, 2.0, "the caller must unblock at the deadline, not wait for the slow fetch")

        // A timeout is not cached as a no-HTML miss, so a retry is a genuinely fresh
        // attempt. With the delay removed, recovery now succeeds and re-fetches
        // rather than re-attaching to the abandoned request.
        mockAPIClient.artificialDelay = 0
        let recovered = await service.recoverHTMLContent(messageId: messageId)

        XCTAssertEqual(recovered, html)
        XCTAssertEqual(mockAPIClient.getMessageCallCount, 2)
    }

    func testAccountTransitionDrainsRecoveryThatAlreadyOutlivedItsDeadline() async throws {
        let messageId = "html-recovery-expired-transition-\(UUID().uuidString)"
        let attachmentId = "html-body-\(UUID().uuidString)"
        let html = "<html><body><p>EXPIRED_OLD_ACCOUNT_HTML</p></body></html>"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLRecoveryExpiredTransition-\(UUID().uuidString)", isDirectory: true)
        let contentHandler = HTMLContentHandler(messagesDirectory: directory)
        defer {
            try? contentHandler.reopenAccountWork()
            try? FileManager.default.removeItem(at: directory)
        }

        let gate = HTMLRecoveryUncooperativeAttachmentGate(data: Data(html.utf8))
        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLAttachmentMessage(
            id: messageId,
            attachmentId: attachmentId
        )
        mockAPIClient.getAttachmentOperation = { _, _ in
            await gate.waitForReleaseIgnoringCancellation()
        }
        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler,
            recoveryNetworkTimeout: 0.02
        )

        let recoveryTask = Task {
            await service.recoverHTMLContent(messageId: messageId)
        }
        await gate.waitUntilStarted()
        let timedOutRecovery = await recoveryTask.value
        XCTAssertNil(
            timedOutRecovery,
            "The caller-facing recovery should return at its deadline"
        )

        contentHandler.closeAccountWork()
        try await contentHandler.deleteAllHTMLFromClosedAccount()
        let drainFinished = HTMLRecoveryThreadSafeFlag()
        let drainTask = Task {
            await service.closeAccountWorkAndAwait()
            drainFinished.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            drainFinished.isSet,
            "Teardown must retain and drain work after its caller-facing deadline"
        )

        await gate.release()
        await drainTask.value

        XCTAssertNil(contentHandler.loadHTML(for: messageId))
    }

    func testAccountTransitionDrainsUncooperativeRecoveryAndRejectsItsStaleWrite() async throws {
        let messageId = "html-recovery-account-transition-\(UUID().uuidString)"
        let attachmentId = "html-body-\(UUID().uuidString)"
        let html = "<html><body><p>OLD_ACCOUNT_HTML</p></body></html>"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLRecoveryAccountTransition-\(UUID().uuidString)", isDirectory: true)
        let contentHandler = HTMLContentHandler(messagesDirectory: directory)
        defer {
            try? contentHandler.reopenAccountWork()
            try? FileManager.default.removeItem(at: directory)
        }

        let gate = HTMLRecoveryUncooperativeAttachmentGate(data: Data(html.utf8))
        let mockAPIClient = MockGmailAPIClient()
        mockAPIClient.getMessageResponses[messageId] = makeHTMLAttachmentMessage(
            id: messageId,
            attachmentId: attachmentId
        )
        mockAPIClient.getAttachmentOperation = { _, _ in
            await gate.waitForReleaseIgnoringCancellation()
        }
        let service = HTMLContentRecoveryService(
            gmailAPIClientProvider: { mockAPIClient },
            contentHandler: contentHandler
        )

        let recoveryTask = Task {
            await service.recoverHTMLContent(messageId: messageId)
        }
        await gate.waitUntilStarted()

        contentHandler.closeAccountWork()
        try await contentHandler.deleteAllHTMLFromClosedAccount()
        let drainFinished = HTMLRecoveryThreadSafeFlag()
        let drainTask = Task {
            await service.closeAccountWorkAndAwait()
            drainFinished.set()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(
            drainFinished.isSet,
            "Account cleanup must wait for a provider call that ignores task cancellation"
        )

        await gate.release()
        await drainTask.value
        let staleRecovery = await recoveryTask.value
        XCTAssertNil(staleRecovery)
        XCTAssertNil(contentHandler.loadHTML(for: messageId))

        try contentHandler.reopenAccountWork()
        await service.reopenAccountWork()
        mockAPIClient.getAttachmentOperation = nil
        mockAPIClient.attachmentResponses["\(messageId):\(attachmentId)"] = Data(html.utf8)

        let freshRecovery = await service.recoverHTMLContent(messageId: messageId)
        XCTAssertEqual(freshRecovery, html)
        XCTAssertEqual(contentHandler.loadHTML(for: messageId), html)
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

private actor HTMLRecoveryUncooperativeAttachmentGate {
    private let data: Data
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Data, Never>] = []

    init(data: Data) {
        self.data = data
    }

    func waitForReleaseIgnoringCancellation() async -> Data {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume(returning: data) }
    }
}

private final class HTMLRecoveryThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
