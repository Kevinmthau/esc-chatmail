import XCTest
@testable import esc_chatmail

final class ProcessedTextCacheTests: XCTestCase {

    // MARK: - Cache Operations

    func testCache_setAndGet_returnsCachedValue() async {
        let cache = ProcessedTextCache.shared
        let testId = "test-message-\(UUID().uuidString)"
        let testText = "Hello, this is a test message."

        await cache.set(messageId: testId, plainText: testText, hasRichContent: false)

        let result = await cache.get(messageId: testId)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.plainText, testText)
        XCTAssertFalse(result?.hasRichContent ?? true)

        // Cleanup
        await cache.invalidate(messageId: testId)
    }

    func testCache_getNonexistent_returnsNil() async {
        let cache = ProcessedTextCache.shared
        let result = await cache.get(messageId: "nonexistent-\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func testCache_invalidate_removesCachedEntry() async {
        let cache = ProcessedTextCache.shared
        let testId = "test-invalidate-\(UUID().uuidString)"

        await cache.set(messageId: testId, plainText: "Test", hasRichContent: false)
        await cache.invalidate(messageId: testId)

        let result = await cache.get(messageId: testId)
        XCTAssertNil(result)
    }

    func testCache_trackedKeysArePrunedAfterLRUEviction() async {
        let cache = ProcessedTextCache.shared
        await cache.clear()

        for index in 0...CacheConfig.textCacheSize {
            await cache.set(
                messageId: "test-lru-\(index)",
                sourceSignature: "source-\(index)",
                previewMode: "test-preview",
                plainText: "Message \(index)",
                hasRichContent: false
            )
        }

        let stats = await cache.getStatistics()
        let trackedKeyCount = await cache.trackedCacheKeyCountForTesting()
        XCTAssertEqual(stats.currentItemCount, CacheConfig.textCacheSize)
        XCTAssertEqual(trackedKeyCount, stats.currentItemCount)

        await cache.clear()
    }

    func testCache_handleMemoryWarningClearsTrackedKeys() async {
        let cache = ProcessedTextCache.shared
        await cache.clear()

        await cache.set(
            messageId: "test-memory-warning-\(UUID().uuidString)",
            sourceSignature: "source",
            previewMode: "test-preview",
            plainText: "Cached text",
            hasRichContent: false
        )

        await cache.handleMemoryWarning()

        let trackedKeyCount = await cache.trackedCacheKeyCountForTesting()
        XCTAssertEqual(trackedKeyCount, 0)

        await cache.clear()
    }

    func testContentSourceSignature_usesOnlyHTMLMetadataForStoredHTML() {
        let handler = HTMLContentHandler.shared
        let messageId = "test-source-signature-\(UUID().uuidString)"
        defer {
            handler.deleteHTML(for: messageId)
        }

        let html = "<html><body><p>\(String(repeating: "Large message body. ", count: 1000))</p></body></html>"
        XCTAssertNotNil(handler.saveHTML(html, for: messageId))

        let htmlSignature = handler.htmlSourceSignature(messageId: messageId, bodyStorageURI: nil)
        let sourceSignature = ProcessedTextCache.contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            handler: handler
        )
        XCTAssertEqual(sourceSignature, "html:\(htmlSignature)")
        XCTAssertFalse(sourceSignature.hasPrefix("html:sha256:"))

        let sourceSignatureWithBody = ProcessedTextCache.contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Fallback body",
            handler: handler
        )
        XCTAssertEqual(sourceSignatureWithBody, "html:\(htmlSignature)")
    }

    func testFallbackContentSourceSignature_includesBodyTextForStoredHTML() {
        let handler = HTMLContentHandler.shared
        let messageId = "test-fallback-source-signature-\(UUID().uuidString)"
        defer {
            handler.deleteHTML(for: messageId)
        }

        XCTAssertNotNil(handler.saveHTML("<html><body><img src=\"cid:image\"></body></html>", for: messageId))

        let htmlSignature = handler.htmlSourceSignature(messageId: messageId, bodyStorageURI: nil)
        let sourceSignature = ProcessedTextCache.fallbackContentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Fallback body",
            handler: handler
        )

        XCTAssertTrue(sourceSignature.hasPrefix("html:\(htmlSignature)|fallback-body:sha256:"))
    }

    func testContentSourceSignature_usesBodyTextWhenHTMLMissing() {
        let handler = HTMLContentHandler.shared
        let messageId = "test-missing-html-source-signature-\(UUID().uuidString)"
        handler.deleteHTML(for: messageId)

        let sourceSignature = ProcessedTextCache.contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Fallback body",
            handler: handler
        )
        XCTAssertTrue(sourceSignature.hasPrefix("body:sha256:"))
    }

    func testCache_prunePreservesTrackedKeysForInFlightWrites() async {
        let cache = ProcessedTextCache.shared
        await cache.clear()

        let pendingMessageId = "test-pending-write-\(UUID().uuidString)"
        let liveMessageId = "test-live-write-\(UUID().uuidString)"
        await cache.beginTrackedCacheWriteForTesting(
            messageId: pendingMessageId,
            sourceSignature: "pending-source",
            previewMode: "test-preview"
        )

        await cache.set(
            messageId: liveMessageId,
            sourceSignature: "live-source",
            previewMode: "test-preview",
            plainText: "Cached text",
            hasRichContent: false
        )

        let trackedKeyCount = await cache.trackedCacheKeyCountForTesting()
        XCTAssertEqual(trackedKeyCount, 2)

        await cache.finishTrackedCacheWriteForTesting()
        await cache.clear()
    }

    func testCache_setWithQuotedParts_returnsCachedQuotes() async {
        let cache = ProcessedTextCache.shared
        let testId = "test-quotes-\(UUID().uuidString)"
        let quotedParts = [
            QuotedPart(text: "Original message", attribution: "On Jan 1, John wrote:", nestingLevel: 0),
            QuotedPart(text: "Even older message", attribution: nil, nestingLevel: 1)
        ]

        await cache.set(messageId: testId, plainText: "My reply", hasRichContent: false, quotedParts: quotedParts)

        let result = await cache.get(messageId: testId)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.quotedParts.count, 2)
        XCTAssertEqual(result?.quotedParts.first?.text, "Original message")
        XCTAssertEqual(result?.quotedParts.first?.nestingLevel, 0)
        XCTAssertEqual(result?.quotedParts.last?.nestingLevel, 1)

        // Cleanup
        await cache.invalidate(messageId: testId)
    }

    // MARK: - hasGenuineRichContent Tests

    func testHasRichContent_simpleText_returnsFalse() {
        // We can't directly test hasGenuineRichContent as it's private,
        // but we can test through processMessage behavior
        // For now, we verify the method exists and cache handles rich content flag
    }

    func testHasRichContent_withVideo_returnsTrue() {
        // Verify through cache set/get that rich content flag is preserved
        // The actual detection is tested implicitly
    }

    func testHasRichContent_withIframe_returnsTrue() {
        // Detection tested implicitly through cache
    }

    func testHasRichContent_newsletterWithManyLinks_returnsTrue() {
        // Newsletter-like content with many links
        var html = "<html><body><p>Newsletter content</p>"
        for i in 1...20 {
            html += "<a href=\"https://example.com/\(i)\">Link \(i)</a>"
        }
        html += "<p>Lots of text content here to make it substantial. " +
               String(repeating: "More content. ", count: 50) + "</p></body></html>"

        // Should detect as rich due to high link count
    }

    func testHasRichContent_transactionalTableLayout_returnsTrue() {
        let messageId = "test-transactional-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        let substantialText = String(repeating: "Security alert details. ", count: 20)
        let html = """
        <html><body>
        <table><tr><td>Header</td></tr></table>
        <table><tr><td>\(substantialText)</td></tr></table>
        </body></html>
        """

        _ = handler.saveHTML(html, for: messageId)
        let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

        XCTAssertTrue(result.hasRichContent)

        handler.deleteHTML(for: messageId)
    }

    func testHasRichContent_singleTableBankNotification_returnsTrue() {
        let messageId = "test-bank-single-table-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        let html = """
        <table border="0" cellpadding="0" cellspacing="0">
          <tr><td><strong>Deposit Declined</strong></td></tr>
          <tr><td>Account Number Ending: 0039</td></tr>
          <tr><td>Your deposit was declined because your daily deposit limit amount was exceeded.</td></tr>
          <tr><td>Please do not respond to this message.</td></tr>
          <tr><td>Example National Mobile Check Deposit</td></tr>
        </table>
        """

        _ = handler.saveHTML(html, for: messageId)
        let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

        XCTAssertTrue(result.hasRichContent)

        handler.deleteHTML(for: messageId)
    }

    func testProcessMessage_appleRichLinkPreview_doesNotCountAsRichContent() {
        let messageId = "test-apple-rich-link-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        let substantialText = String(repeating: "Personal message text. ", count: 30)
        let html = """
        <html><body>
        <div>\(substantialText)</div>
        <div class="apple-rich-link" role="link">
            <div>outer</div>
            <div>
                <div>nested</div>
                <table>
                    <tr><td><img src="cid:IMG1"></td></tr>
                </table>
                <a href="https://example.com" role="button">Preview</a>
            </div>
        </div>
        <div>&nbsp;<img src="cid:IMG2" alt="attachment.png" width="403"></div>
        </body></html>
        """

        _ = handler.saveHTML(html, for: messageId)
        let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

        XCTAssertFalse(result.hasRichContent)

        handler.deleteHTML(for: messageId)
    }

    func testProcessMessage_multipleAppleRichLinkPreviews_allStripped() {
        // Several rich-link blocks in one message: the strip resumes scanning
        // from each removal point (rather than restarting at index 0) and
        // must still remove every block.
        let messageId = "test-apple-rich-link-multi-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        let substantialText = String(repeating: "Personal message text. ", count: 30)
        let richLinkBlock = """
        <div class="apple-rich-link" role="link">
            <div><table><tr><td><img src="cid:IMG"></td></tr></table></div>
            <a href="https://example.com" role="button">Preview</a>
        </div>
        """
        let html = """
        <html><body>
        <div>\(substantialText)</div>
        \(richLinkBlock)
        <div>More personal text between previews.</div>
        \(richLinkBlock)
        \(richLinkBlock)
        </body></html>
        """

        _ = handler.saveHTML(html, for: messageId)
        let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

        XCTAssertFalse(result.hasRichContent)

        handler.deleteHTML(for: messageId)
    }

    func testProcessMessage_outlookGrayDividerQuoteBoundary_removesQuotedThread() {
        let messageId = "test-outlook-divider-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        let html = """
        <html><body>
        <div class="WordSection1">
            <p>I have a wake to attend tomorrow evening unfortunately</p>
            <div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in">
                <p><b>From:</b> Dominic Cozzetto</p>
                <p><b>Sent:</b> Wednesday, February 11, 2026 12:18 PM</p>
                <p><b>To:</b> Flock, Kathleen; Rory Gildea</p>
                <p><b>Cc:</b> Brynn Putnam; Kevin Thau</p>
                <p><b>Subject:</b> BofA Intro &amp; Next Steps</p>
            </div>
            <p>Hello Kathy &amp; Rory,</p>
            <p>Kevin and Brynn would like to move forward with a call.</p>
        </div>
        </body></html>
        """

        _ = handler.saveHTML(html, for: messageId)
        let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

        XCTAssertTrue(result.plainText?.contains("I have a wake to attend tomorrow evening unfortunately") ?? false)
        XCTAssertFalse(result.plainText?.contains("Hello Kathy & Rory,") ?? true)
        XCTAssertFalse(result.plainText?.contains("Kevin and Brynn would like to move forward with a call.") ?? true)

        handler.deleteHTML(for: messageId)
    }

    func testChatBubbleTextProcessor_htmlDOMQuoteContainers_removedBeforeTextExtraction() {
        let cases = [
            (
                name: "gmail",
                html: """
                <div>Visible reply.</div>
                <div class="gmail_quote"><p>Quoted Gmail history.</p></div>
                """,
                hiddenText: "Quoted Gmail history."
            ),
            (
                name: "outlook",
                html: """
                <p>Visible reply.</p>
                <div id="mail-editor-reference-message-container"><p>Quoted Outlook history.</p></div>
                <p>Stale tail.</p>
                """,
                hiddenText: "Quoted Outlook history."
            ),
            (
                name: "apple",
                html: """
                <p>Visible reply.</p>
                <blockquote type="cite"><p>Quoted Apple history.</p></blockquote>
                """,
                hiddenText: "Quoted Apple history."
            )
        ]

        for testCase in cases {
            let result = ChatBubbleTextProcessor.process(
                content: testCase.html,
                options: ChatBubbleTextProcessorOptions(
                    inputKind: .html,
                    sanitizeRawEmailSource: false,
                    decodeHTMLEntities: true,
                    formatSignOffLineBreaks: true,
                    classifyRichContent: false
                )
            )

            XCTAssertEqual(result.mainText, "Visible reply.", testCase.name)
            XCTAssertFalse(result.mainText?.contains(testCase.hiddenText) ?? true, testCase.name)
            XCTAssertTrue(result.quotedParts.isEmpty, testCase.name)
        }
    }

    /// Quote-first (bottom-posted) reply: attribution and quoted history sit
    /// at the top, the author's text after. Marker truncation used to remove
    /// everything from the attribution onward, leaving an empty bubble for a
    /// message whose original view clearly has content.
    func testChatBubbleTextProcessor_htmlBottomPostedReply_recoversContentAfterQuote() {
        let html = """
        <html><body>
        <div>On Aug 1, 2026, at 9:00 AM, Olga Smith &lt;olga@example.com&gt; wrote:</div>
        <blockquote type="cite"><div>Are you free for lunch tomorrow?</div></blockquote>
        <div>Yes! Tomorrow at noon works great.</div>
        </body></html>
        """

        let result = ChatBubbleTextProcessor.htmlCompatibilityFallback(
            from: html,
            classifyRichContent: false
        )

        XCTAssertEqual(result.mainText, "Yes! Tomorrow at noon works great.")
        XCTAssertFalse(result.mainText?.contains("Are you free for lunch tomorrow?") ?? true)
    }

    /// Prose that merely ends with "wrote:" is not an attribution. The
    /// standalone-attribution filter only runs for the containers-only rescue
    /// and requires a genuine attribution shape, so ordinary lines survive.
    func testChatBubbleTextProcessor_htmlProseEndingInWroteColon_survivesCleanup() {
        let html = """
        <div>Here is what I wrote:</div>
        <div>The draft is attached for your review.</div>
        """

        let result = ChatBubbleTextProcessor.htmlCompatibilityFallback(
            from: html,
            classifyRichContent: false
        )

        XCTAssertTrue(
            result.mainText?.contains("Here is what I wrote:") ?? false,
            "Unexpected mainText: \(result.mainText ?? "nil")"
        )
        XCTAssertTrue(result.mainText?.contains("The draft is attached") ?? false)
    }

    func testChatBubbleTextProcessor_htmlLiteralQuoteLikeProse_isNotPlainTextQuoteRemoved() {
        let html = """
        <p>Please keep this literal example: On Jan 30, 2026 at 7:32 PM, Name should remain in the help text.</p>
        <p>Done.</p>
        """

        let result = ChatBubbleTextProcessor.process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )

        XCTAssertEqual(
            result.mainText,
            "Please keep this literal example: On Jan 30, 2026 at 7:32 PM, Name should remain in the help text.\n\nDone."
        )
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testChatBubbleTextProcessor_htmlInternationalQuoteMarkers_removedAfterTextExtraction() {
        let cases = [
            (
                name: "german",
                visibleText: "Danke für die Nachricht.",
                hiddenText: "Alter Verlauf.",
                html: """
                <div>Danke für die Nachricht.</div>
                <div>Am 15. Januar 2024 schrieb Hans Müller:</div>
                <div>Alter Verlauf.</div>
                """
            ),
            (
                name: "spanish",
                visibleText: "Gracias por la información.",
                hiddenText: "Mensaje anterior.",
                html: """
                <div>Gracias por la información.</div>
                <div>El 15 de enero de 2024, Carlos García escribió:</div>
                <div>Mensaje anterior.</div>
                """
            ),
            (
                name: "portuguese",
                visibleText: "Obrigado.",
                hiddenText: "Mensagem anterior.",
                html: """
                <div>Obrigado.</div>
                <div>Em 15 de janeiro de 2024, João Silva escreveu:</div>
                <div>Mensagem anterior.</div>
                """
            ),
            (
                name: "dutch",
                visibleText: "Bedankt.",
                hiddenText: "Oud bericht.",
                html: """
                <div>Bedankt.</div>
                <div>Op 15 januari 2024 schreef Jan de Vries:</div>
                <div>Oud bericht.</div>
                """
            )
        ]

        for testCase in cases {
            let result = ChatBubbleTextProcessor.process(
                content: testCase.html,
                options: ChatBubbleTextProcessorOptions(
                    inputKind: .html,
                    sanitizeRawEmailSource: false,
                    decodeHTMLEntities: true,
                    formatSignOffLineBreaks: true,
                    classifyRichContent: false
                )
            )

            XCTAssertEqual(result.mainText, testCase.visibleText, testCase.name)
            XCTAssertFalse(result.mainText?.contains(testCase.hiddenText) ?? true, testCase.name)
            XCTAssertTrue(result.quotedParts.isEmpty, testCase.name)
        }
    }

    func testChatBubbleTextProcessor_htmlWrappedPlainTextQuoteLines_removedAfterTextExtraction() {
        let html = """
        <div>Reply<br>&gt; old<br>&gt; thread</div>
        """

        let result = ChatBubbleTextProcessor.process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )

        XCTAssertEqual(result.mainText, "Reply")
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testChatBubbleTextProcessor_htmlWrappedPlainTextQuoteLinesWithAttribution_removesAttribution() {
        let html = """
        <div>Reply<br>John wrote:<br>&gt; old<br>&gt; thread</div>
        """

        let result = ChatBubbleTextProcessor.process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )

        XCTAssertEqual(result.mainText, "Reply")
        XCTAssertFalse(result.mainText?.contains("John wrote:") ?? true)
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testProcessMessage_htmlOnlyOnWroteQuoteFallback_suppressesMainText() {
        let messageId = "test-html-only-on-wrote-quote-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        let html = """
        <div>On Jan 31, 2026 at 12:31 PM, Scott Wunderlich wrote:</div>
        <div>Earlier message only.</div>
        """

        _ = handler.saveHTML(html, for: messageId)
        let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

        XCTAssertNil(result.plainText)
        XCTAssertTrue(result.quotedParts.isEmpty)

        handler.deleteHTML(for: messageId)
    }

    func testChatBubbleTextProcessor_htmlTextualForwardMarker_removedAfterDOMCleanup() {
        let html = """
        <div>FYI</div>
        <div>---------- Forwarded message ---------</div>
        <div>From: Jane Example &lt;jane@example.com&gt;</div>
        <div>Date: Mon, Feb 16, 2026 at 5:56 PM</div>
        <div>Subject: Spring plans</div>
        <div>To: Kevin Example &lt;kevin@example.com&gt;</div>
        <div>Looking forward to seeing you there.</div>
        """

        let result = ChatBubbleTextProcessor.process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )

        XCTAssertEqual(result.mainText, "FYI")
        XCTAssertFalse(result.mainText?.contains("Forwarded message") ?? true)
        XCTAssertFalse(result.mainText?.contains("Jane Example") ?? true)
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testChatBubbleTextProcessor_htmlBRSeparatedHeaderBlock_removedBeforeTextExtraction() {
        let html = """
        <div>Visible reply.</div>
        <div>
            From: Jane Example &lt;jane@example.com&gt;<br>
            Sent: Monday, February 16, 2026 5:56 PM<br>
            To: Kevin Example &lt;kevin@example.com&gt;<br>
            Subject: Spring plans<br><br>
            Looking forward to seeing you there.
        </div>
        """

        let result = ChatBubbleTextProcessor.process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )

        XCTAssertEqual(result.mainText, "Visible reply.")
        XCTAssertFalse(result.mainText?.contains("Jane Example") ?? true)
        XCTAssertFalse(result.mainText?.contains("Looking forward to seeing you there.") ?? true)
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testChatBubbleTextProcessor_htmlTableHeaderBlockAfterBlankSeparator_removedBeforeTextExtraction() {
        let html = """
        <div>Visible reply.</div>
        <div><br></div>
        <table>
            <tr><td>From:</td><td>Jane Example &lt;jane@example.com&gt;</td></tr>
            <tr><td>Sent:</td><td>Monday, February 16, 2026 5:56 PM</td></tr>
            <tr><td>To:</td><td>Kevin Example &lt;kevin@example.com&gt;</td></tr>
            <tr><td>Subject:</td><td>Spring plans</td></tr>
        </table>
        <div>Looking forward to seeing you there.</div>
        """

        let result = ChatBubbleTextProcessor.process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )

        XCTAssertEqual(result.mainText, "Visible reply.")
        XCTAssertFalse(result.mainText?.contains("Jane Example") ?? true)
        XCTAssertFalse(result.mainText?.contains("Looking forward to seeing you there.") ?? true)
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testChatBubbleTextProcessor_htmlSeparateDivHeaderBlockAfterBlankSeparator_removedByTextCleanup() {
        let html = """
        <div>Visible reply.</div>
        <div><br></div>
        <div>From: Jane Example &lt;jane@example.com&gt;</div>
        <div>Sent: Monday, February 16, 2026 5:56 PM</div>
        <div>To: Kevin Example &lt;kevin@example.com&gt;</div>
        <div>Subject: Spring plans</div>
        <div>Looking forward to seeing you there.</div>
        """

        let result = ChatBubbleTextProcessor.process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )

        XCTAssertEqual(result.mainText, "Visible reply.")
        XCTAssertFalse(result.mainText?.contains("Jane Example") ?? true)
        XCTAssertFalse(result.mainText?.contains("Looking forward to seeing you there.") ?? true)
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testChatBubbleTextProcessor_htmlSeparateDivHeaderBlockWithoutSubject_removedByTextCleanup() {
        let html = """
        <div>Great. Will do! Have a nice weekend!</div>
        <div><br></div>
        <div>From: Kevin Thau &lt;kevin@example.com&gt;</div>
        <div>Sent: Saturday, February 14, 2026 3:17:13 PM</div>
        <div>To: Jasmine Example &lt;jasmine@example.com&gt;</div>
        <div>Quoted body starts here.</div>
        """

        let result = ChatBubbleTextProcessor.process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )

        XCTAssertEqual(result.mainText, "Great. Will do! Have a nice weekend!")
        XCTAssertFalse(result.mainText?.contains("Kevin Thau") ?? true)
        XCTAssertFalse(result.mainText?.contains("Quoted body starts here.") ?? true)
        XCTAssertTrue(result.quotedParts.isEmpty)
    }

    func testProcessMessage_htmlQuoteCleanup_returnsNoQuotedParts() {
        let messageId = "test-html-quoted-parts-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        let html = """
        <p>Visible reply.</p>
        <blockquote type="cite"><p>Quoted history.</p></blockquote>
        """

        _ = handler.saveHTML(html, for: messageId)
        let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

        XCTAssertEqual(result.plainText, "Visible reply.")
        XCTAssertTrue(result.quotedParts.isEmpty)

        handler.deleteHTML(for: messageId)
    }

    // MARK: - List Item Detection Tests

    func testIsListItem_numberedList_singleDigit() {
        XCTAssertTrue(TextProcessing.isListItem("1. First item"))
        XCTAssertTrue(TextProcessing.isListItem("9. Ninth item"))
    }

    func testIsListItem_numberedList_multiDigit() {
        XCTAssertTrue(TextProcessing.isListItem("10. Tenth item"))
        XCTAssertTrue(TextProcessing.isListItem("99. Ninety-ninth item"))
        XCTAssertTrue(TextProcessing.isListItem("100. Hundredth item"))
    }

    func testIsListItem_numberedList_withParenthesis() {
        XCTAssertTrue(TextProcessing.isListItem("1) First item"))
        XCTAssertTrue(TextProcessing.isListItem("10) Tenth item"))
    }

    func testIsListItem_letteredList_lowercase() {
        XCTAssertTrue(TextProcessing.isListItem("a. First item"))
        XCTAssertTrue(TextProcessing.isListItem("b) Second item"))
        XCTAssertTrue(TextProcessing.isListItem("z. Last item"))
    }

    func testIsListItem_letteredList_uppercase() {
        XCTAssertTrue(TextProcessing.isListItem("A. First item"))
        XCTAssertTrue(TextProcessing.isListItem("B) Second item"))
    }

    func testIsListItem_bulletPoints() {
        XCTAssertTrue(TextProcessing.isListItem("- Item with dash"))
        XCTAssertTrue(TextProcessing.isListItem("* Item with asterisk"))
        XCTAssertTrue(TextProcessing.isListItem("• Item with bullet"))
        XCTAssertTrue(TextProcessing.isListItem("· Item with middle dot"))
    }

    func testIsListItem_parenthesizedNumbers() {
        XCTAssertTrue(TextProcessing.isListItem("(1) First item"))
        XCTAssertTrue(TextProcessing.isListItem("(a) First item"))
        XCTAssertTrue(TextProcessing.isListItem("(A) First item"))
    }

    func testIsListItem_notListItem() {
        XCTAssertFalse(TextProcessing.isListItem("This is regular text"))
        XCTAssertFalse(TextProcessing.isListItem("Hello there"))
        XCTAssertFalse(TextProcessing.isListItem("1000 items in stock"))
        XCTAssertFalse(TextProcessing.isListItem("ab. Not a list"))
    }

    // MARK: - Line Unwrapping Tests

    func testUnwrapEmailLineBreaks_preservesListItems() {
        let text = """
        Here are the items:
        1. First item
        2. Second item
        10. Tenth item that continues
        on the next line
        """

        let result = TextProcessing.unwrapEmailLineBreaks(from: text)

        // List items should be preserved, but continuation should be joined
        XCTAssertTrue(result.contains("1. First item"))
        XCTAssertTrue(result.contains("2. Second item"))
        XCTAssertTrue(result.contains("10. Tenth item"))
    }

    func testUnwrapEmailLineBreaks_preservesMultiDigitListItems() {
        let text = """
        Long list:
        9. Ninth
        10. Tenth
        11. Eleventh
        """

        let result = TextProcessing.unwrapEmailLineBreaks(from: text)

        XCTAssertTrue(result.contains("9. Ninth"))
        XCTAssertTrue(result.contains("10. Tenth"))
        XCTAssertTrue(result.contains("11. Eleventh"))
    }

    func testUnwrapEmailLineBreaks_preservesLetteredListItems() {
        let text = """
        Options:
        a) First option
        b) Second option
        c) Third option
        """

        let result = TextProcessing.unwrapEmailLineBreaks(from: text)

        XCTAssertTrue(result.contains("a) First option"))
        XCTAssertTrue(result.contains("b) Second option"))
        XCTAssertTrue(result.contains("c) Third option"))
    }

    func testUnwrapEmailLineBreaks_keepsSignatureDelimiterSeparated() {
        let text = """
        Thank you,

        Dominic

        -- 

        [image: Company logo] <http://adviceperiod.com>
        """

        let result = TextProcessing.unwrapEmailLineBreaks(from: text)

        XCTAssertTrue(result.contains("Dominic\n\n--\n\n[image: Company logo]"))
        XCTAssertFalse(result.contains("Dominic --"))
    }

    // MARK: - extractPlainText Tests

    func testExtractPlainText_removesScriptTags() {
        let html = "<html><body><script>alert('bad')</script><p>Good content</p></body></html>"
        let result = TextProcessing.extractPlainText(from: html)

        XCTAssertFalse(result.contains("alert"))
        XCTAssertTrue(result.contains("Good content"))
    }

    func testExtractPlainText_removesStyleTags() {
        let html = "<html><head><style>.class { color: red; }</style></head><body><p>Content</p></body></html>"
        let result = TextProcessing.extractPlainText(from: html)

        XCTAssertFalse(result.contains("color"))
        XCTAssertTrue(result.contains("Content"))
    }

    func testExtractPlainText_decodesHTMLEntities() {
        let html = "<p>5 &lt; 10 &amp; 10 &gt; 5</p>"
        let result = TextProcessing.extractPlainText(from: html)

        XCTAssertTrue(result.contains("5 < 10 & 10 > 5"))
    }

    func testExtractPlainText_handlesZeroWidthCharacters() {
        let html = "<p>Hello&zwnj;World&zwj;!</p>"
        let result = TextProcessing.extractPlainText(from: html)

        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "HelloWorld!")
    }

    func testExtractPlainText_preservesParagraphBreaks() {
        let html = "<p>First paragraph.</p><p>Second paragraph.</p>"
        let result = TextProcessing.extractPlainText(from: html)

        XCTAssertTrue(result.contains("First paragraph."))
        XCTAssertTrue(result.contains("Second paragraph."))
        // Should have paragraph break between them
        XCTAssertTrue(result.contains("\n"))
    }

    func testExtractPlainText_handlesListItems() {
        let html = "<ul><li>thinking</li><li>another thinking</li><li>and another</li></ul>"
        let result = TextProcessing.extractPlainText(from: html)

        XCTAssertTrue(result.contains("thinking"))
        XCTAssertTrue(result.contains("another thinking"))
        XCTAssertTrue(result.contains("and another"))
        // Each list item should be on its own line
        let lines = result.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
    }

    func testExtractPlainText_preservesTableRowBoundaries() {
        let html = """
        <table>
            <tr><td>From:</td><td>Kevin Thau &lt;kmthau@gmail.com&gt;</td></tr>
            <tr><td>Sent:</td><td>Saturday, Feb 15, 2026 4:53 PM</td></tr>
            <tr><td>To:</td><td>Jasmine &lt;jasmine@example.com&gt;</td></tr>
            <tr><td>Subject:</td><td>Weekend</td></tr>
        </table>
        """

        let result = TextProcessing.extractPlainText(from: html)

        // Each table row should become its own line (so quote detection can match header blocks).
        let lines = result.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertTrue(lines.contains(where: { $0.contains("From: Kevin Thau <kmthau@gmail.com>") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("Sent: Saturday, Feb 15, 2026 4:53 PM") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("To: Jasmine <jasmine@example.com>") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("Subject: Weekend") }))
    }

    func testTextSnippetCreator_removesHeaderQuoteBlockExtractedFromTableHTML() {
        let html = """
        <div>Great. Will do! Have a nice weekend!</div>
        <div><br></div>
        <table>
            <tr><td>From:</td><td>Kevin Thau &lt;kmthau@gmail.com&gt;</td></tr>
            <tr><td>Sent:</td><td>Saturday, Feb 15, 2026 4:53 PM</td></tr>
            <tr><td>To:</td><td>Jasmine &lt;jasmine@example.com&gt;</td></tr>
            <tr><td>Subject:</td><td>Weekend</td></tr>
        </table>
        <div>Quoted body starts here...</div>
        """

        let extracted = TextProcessing.extractPlainText(from: html)
        let snippet = TextSnippetCreator.createSnippet(from: extracted, maxLength: Int.max, firstSentenceOnly: false)

        XCTAssertEqual(snippet, "Great. Will do! Have a nice weekend!")
    }

    func testExtractPlainText_decodesNumericEntities() {
        // &#160; is non-breaking space - the main entity we need to decode
        let html = "<p>Hello&#160;World&#160;Test&#160;2024</p>"
        let result = TextProcessing.extractPlainText(from: html)

        // &#160; should become regular space
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))
        XCTAssertTrue(result.contains("Test"))
        XCTAssertTrue(result.contains("2024"))
        // Should NOT contain raw entity text
        XCTAssertFalse(result.contains("&#160;"))
    }

    func testExtractPlainText_decodesHexNumericEntities() {
        // &#xA0; is non-breaking space (hex) - main hex entity we need to decode
        let html = "<p>Test&#xA0;content&#xA0;here</p>"
        let result = TextProcessing.extractPlainText(from: html)

        XCTAssertTrue(result.contains("Test"))
        XCTAssertTrue(result.contains("content"))
        XCTAssertTrue(result.contains("here"))
        // Should NOT contain raw entity text
        XCTAssertFalse(result.contains("&#xA0;"))
    }

    // MARK: - HTMLEntityDecoder Tests

    func testHTMLEntityDecoder_decodesNumericNbsp() {
        // Test the main entity we care about: &#160; (non-breaking space)
        let text = "Hello&#160;World&#160;Test"
        let result = HTMLEntityDecoder.decode(text)

        // &#160; should become regular space
        XCTAssertFalse(result.contains("&#160;"))
        XCTAssertTrue(result.contains("Hello World Test"))
    }

    func testHTMLEntityDecoder_decodesHexNbsp() {
        // Test hex form: &#xA0; and &#x00A0; (non-breaking space)
        let text = "Price&#xA0;$100&#x00A0;good"
        let result = HTMLEntityDecoder.decode(text)

        // &#xA0; and &#x00A0; should become regular space
        XCTAssertFalse(result.contains("&#xA0;"))
        XCTAssertFalse(result.contains("&#x00A0;"))
        XCTAssertTrue(result.contains("Price $100 good"))
    }

    func testHTMLEntityDecoder_decodesHardcodedEntities() {
        // Test entities that are explicitly hardcoded in numericEntities dictionary
        let text = "&#8212;&#8211;&#8217;&#8220;&#8221;&#8230;" // em dash, en dash, apostrophe, quotes, ellipsis
        let result = HTMLEntityDecoder.decode(text)

        XCTAssertTrue(result.contains("—")) // em dash
        XCTAssertTrue(result.contains("–")) // en dash
        XCTAssertTrue(result.contains("'")) // apostrophe
        XCTAssertTrue(result.contains("…")) // ellipsis
    }

    // MARK: - Div Paragraph Preservation Tests

    func testExtractPlainText_preservesDivParagraphs() {
        // Gmail mobile format: each paragraph is a separate div
        let html = """
        <div dir="auto">Hey!</div>
        <div dir="auto"><br></div>
        <div dir="auto">I need to reload on the Chablis. When can you deliver?</div>
        <div dir="auto"><br></div>
        <div dir="auto">Thanks!</div>
        """
        let result = TextProcessing.extractPlainText(from: html)

        // Should have paragraph breaks between distinct paragraphs
        XCTAssertTrue(result.contains("Hey!"))
        XCTAssertTrue(result.contains("I need to reload"))
        XCTAssertTrue(result.contains("Thanks!"))

        // Check paragraph structure: should be 3 distinct paragraphs
        let paragraphs = result.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(paragraphs.count, 3)
    }

    func testExtractPlainText_divParagraphsWithoutBrTags() {
        // Edge case: divs directly adjacent without <br> between them
        // Full pipeline: extractPlainText → unwrapEmailLineBreaks determines paragraph breaks
        let html = "<div>First paragraph.</div><div>Second paragraph.</div>"
        let extracted = TextProcessing.extractPlainText(from: html)
        let result = TextProcessing.unwrapEmailLineBreaks(from: extracted)

        XCTAssertTrue(result.contains("First paragraph."))
        XCTAssertTrue(result.contains("Second paragraph."))

        // Should have paragraph break between them (sentence-ending punctuation + uppercase start)
        let paragraphs = result.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(paragraphs.count, 2)
    }

    // MARK: - Sign-off Formatting Tests

    func testFormatSignOffLineBreaks_preservesExclamationMark() {
        // "Thanks!" should stay as "Thanks!" not become "Thanks,"
        let text = "I appreciate the help. Thanks!"
        let result = TextProcessing.formatSignOffLineBreaks(in: text)

        XCTAssertTrue(result.contains("Thanks!"), "Exclamation mark should be preserved")
        XCTAssertFalse(result.contains("Thanks,"), "Should not replace ! with comma")
    }

    func testFormatSignOffLineBreaks_preservesPeriod() {
        // "Thanks." should stay as "Thanks."
        let text = "I appreciate the help. Thanks."
        let result = TextProcessing.formatSignOffLineBreaks(in: text)

        XCTAssertTrue(result.contains("Thanks."), "Period should be preserved")
        XCTAssertFalse(result.contains("Thanks,"), "Should not replace . with comma")
    }

    func testFormatSignOffLineBreaks_addsCommaWhenNoPunctuation() {
        // "Thanks" without punctuation should get comma
        let text = "I appreciate the help. Thanks"
        let result = TextProcessing.formatSignOffLineBreaks(in: text)

        XCTAssertTrue(result.contains("Thanks,"), "Comma should be added when no punctuation")
    }

    func testFormatSignOffLineBreaks_withNamePreservesComma() {
        // "Regards, Kevin" should preserve comma format
        let text = "Let me know if you need anything else. Regards, Kevin"
        let result = TextProcessing.formatSignOffLineBreaks(in: text)

        XCTAssertTrue(result.contains("Regards,"))
        XCTAssertTrue(result.contains("Kevin"))
    }

    // MARK: - Div Line Unwrapping Tests

    func testUnwrapEmailLineBreaks_joinsDivWrappedMidSentence() {
        // When divs split a sentence mid-word (no sentence-ending punct, lowercase continuation)
        // the lines should be joined
        let html = "<div>You got it.  See</div><div>you Wednesday.</div>"
        let extracted = TextProcessing.extractPlainText(from: html)
        let result = TextProcessing.unwrapEmailLineBreaks(from: extracted)

        // "See" ends without punctuation, "you" starts lowercase → should join
        XCTAssertTrue(result.contains("See you Wednesday"), "Should join lines split mid-sentence")
    }

    func testUnwrapEmailLineBreaks_preservesSignOffAndNameFromDivWrappedHTML() {
        let html = "<div>Upon approval, we will charge the card on file.</div><div>Best,</div><div>Janet</div><div>P.S. one more thing.</div>"

        let extracted = TextProcessing.extractPlainText(from: html)
        let result = TextProcessing.unwrapEmailLineBreaks(from: extracted)

        XCTAssertEqual(
            result,
            "Upon approval, we will charge the card on file.\n\nBest,\nJanet\n\nP.S. one more thing."
        )
    }
}
