import XCTest
@testable import esc_chatmail

final class MessageBubbleLoaderTests: XCTestCase {

    /// The loader is a Sendable class (not an actor) precisely so concurrent
    /// per-row loads don't serialize; this pins that concurrent use from many
    /// tasks stays correct (races would surface here under the sanitizer).
    func testLoadSenderInfo_isSafeUnderConcurrentUse() async {
        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let names = await withTaskGroup(of: String.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let result = await loader.loadSenderInfo(
                        from: MessageBubbleSenderRequest(
                            email: "sender\(index)@example.com",
                            personDisplayName: nil,
                            personAvatarURL: nil,
                            headerDisplayName: "Sender \(index)"
                        )
                    )
                    return result.name ?? "<nil>"
                }
            }
            var collected: [String] = []
            for await name in group {
                collected.append(name)
            }
            return collected
        }

        XCTAssertEqual(names.count, 32)
        XCTAssertEqual(Set(names).count, 32, "each request should resolve its own sender name")
    }

    func testLoadSenderInfo_noDisplayNameOrContactUsesUnknownSender() async {
        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadSenderInfo(
            from: MessageBubbleSenderRequest(
                email: "john.smith@example.com",
                personDisplayName: nil,
                personAvatarURL: nil
            )
        )

        XCTAssertEqual(result.name, "Unknown Sender")
    }

    func testLoadSenderInfo_usesExplicitHeaderDisplayName() async {
        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadSenderInfo(
            from: MessageBubbleSenderRequest(
                email: "john.smith@example.com",
                personDisplayName: nil,
                personAvatarURL: nil,
                headerDisplayName: "John Smith"
            )
        )

        XCTAssertEqual(result.name, "John Smith")
    }

    func testLoadSenderInfo_preservesExplicitBrandNameMatchingEmailLocalPart() async {
        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadSenderInfo(
            from: MessageBubbleSenderRequest(
                email: "a16z@substack.com",
                personDisplayName: nil,
                personAvatarURL: nil,
                headerDisplayName: "a16z"
            )
        )

        XCTAssertEqual(result.name, "a16z")
    }

    func testLoadSenderInfo_omitsPlainRawLocalPartHeaderName() async {
        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let storedNameResult = await loader.loadSenderInfo(
            from: MessageBubbleSenderRequest(
                email: "john@example.com",
                personDisplayName: "John Appleseed",
                personAvatarURL: nil,
                headerDisplayName: "john"
            )
        )
        let fallbackResult = await loader.loadSenderInfo(
            from: MessageBubbleSenderRequest(
                email: "noreply@example.com",
                personDisplayName: nil,
                personAvatarURL: nil,
                headerDisplayName: "noreply"
            )
        )

        XCTAssertEqual(storedNameResult.name, "John Appleseed")
        XCTAssertEqual(fallbackResult.name, "Unknown Sender")
    }

    func testLoadSenderInfo_contactNameOverridesMissingHeaderName() async {
        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [
                "john.smith@example.com": ContactMatch(
                    displayName: "Address Book John",
                    email: "john.smith@example.com",
                    imageData: nil,
                    contactIdentifier: "contact-john"
                )
            ])
        )

        let result = await loader.loadSenderInfo(
            from: MessageBubbleSenderRequest(
                email: "john.smith@example.com",
                personDisplayName: nil,
                personAvatarURL: nil
            )
        )

        XCTAssertEqual(result.name, "Address Book John")
    }

    func testLoadSenderInfo_prefersContactNameOverHeaderName() async {
        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [
                "bubble-priority@example.com": ContactMatch(
                    displayName: "Address Book Name",
                    email: "bubble-priority@example.com",
                    imageData: nil,
                    contactIdentifier: "contact-bubble"
                )
            ])
        )

        let result = await loader.loadSenderInfo(
            from: MessageBubbleSenderRequest(
                email: "bubble-priority@example.com",
                personDisplayName: nil,
                personAvatarURL: nil,
                headerDisplayName: "Header Alias"
            )
        )

        XCTAssertEqual(result.name, "Address Book Name")
    }

    func testLoadContent_incomingMessagePrefersChatPreviewTextOverRuntimeBodyText() async {
        let messageId = "bubble-chat-preview-primary-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: "Runtime body fallback",
                chatPreviewText: "Canonical chat preview\n\nSecond line",
                bodyStorageURI: nil,
                cleanedSnippet: "List-safe fallback",
                snippet: "Snippet fallback",
                subject: "Chat preview",
                senderName: "Alice Example",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Canonical chat preview\n\nSecond line")
        XCTAssertFalse(result.hasRichHTMLContent)
    }

    func testLoadContent_populatedChatPreviewTextUsesStoredTextWithoutHTMLRecovery() async {
        let messageId = "bubble-chat-preview-no-recovery-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let recoverer = CountingHTMLContentRecoverer(
            recoveredHTMLByMessageID: [
                messageId: "<html><body><p>Recovered text that should not win</p></body></html>"
            ]
        )
        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlContentRecoveryService: recoverer,
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: nil,
                chatPreviewText: "Canonical stored preview",
                bodyStorageURI: nil,
                cleanedSnippet: "Snippet fallback",
                snippet: "Snippet fallback",
                subject: "Stored preview",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Canonical stored preview")
        let recoveryCallCount = await recoverer.recoveryCallCount()
        XCTAssertEqual(recoveryCallCount, 0)
    }

    func testLoadContent_htmlMessageMissingChatPreviewTextUsesDOMFallback() async {
        let messageId = "bubble-html-dom-fallback-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        _ = HTMLContentHandler.shared.saveHTML(
            """
            <html>
            <body>
              <p>Fresh DOM body.</p>
              <div class="gmail_quote">
                <p>Quoted content that should be removed.</p>
              </div>
            </body>
            </html>
            """,
            for: messageId
        )

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: nil,
                chatPreviewText: nil,
                bodyStorageURI: nil,
                cleanedSnippet: "Snippet fallback",
                snippet: "Snippet fallback",
                subject: "HTML fallback",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Fresh DOM body.")
    }

    func testLoadContent_plainTextOnlyMessageUsesNarrowLegacyCleanup() async {
        let messageId = "bubble-plain-text-only-fallback-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                Fresh reply.

                Sent from my iPhone

                On Tue, Jan 2, 2026 at 9:41 AM Alice Example <alice@example.com> wrote:
                > Old quoted content.
                """,
                chatPreviewText: nil,
                bodyStorageURI: nil,
                cleanedSnippet: "Fresh reply.",
                snippet: "Fresh reply.",
                subject: "Plain fallback",
                senderName: "Alice Example",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Fresh reply.")
    }

    func testLoadContent_outgoingOptimisticChatPreviewPreservesParagraphBreaks() async {
        let messageId = "bubble-outgoing-optimistic-preview-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let composedPreview = """
        First paragraph.

        Second paragraph.

        Third paragraph.
        """

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: "First paragraph.",
                chatPreviewText: composedPreview,
                bodyStorageURI: nil,
                cleanedSnippet: "First paragraph.",
                snippet: "First paragraph.",
                subject: "Optimistic send",
                senderName: "Me",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, composedPreview)
    }

    func testLoadContent_legacyRecordWithNilChatPreviewTextUsesBodyFallback() async {
        let messageId = "bubble-legacy-nil-chat-preview-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                Legacy body fallback.

                On Tue, Jan 2, 2026 at 9:41 AM Alice Example <alice@example.com> wrote:
                > Older reply.
                """,
                chatPreviewText: nil,
                bodyStorageURI: nil,
                cleanedSnippet: "Truncated snippet",
                snippet: "Truncated snippet",
                subject: "Legacy fallback",
                senderName: "Alice Example",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Legacy body fallback.")
    }

    func testLoadContent_blankChatPreviewTextFallsBackToProcessedLegacyText() async {
        let messageId = "bubble-blank-chat-preview-fallback-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: "Legacy processed fallback",
                chatPreviewText: " \n\t ",
                bodyStorageURI: nil,
                cleanedSnippet: "Snippet fallback",
                snippet: "Snippet fallback",
                subject: "Blank chat preview",
                senderName: "Alice Example",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Legacy processed fallback")
        XCTAssertFalse(result.hasRichHTMLContent)
    }

    func testLoadContent_incomingMessageFallsBackToRecoveredHTMLTextWhenChatPreviewMissing() async {
        let messageId = "bubble-recovered-preview-fallback-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlContentRecoveryService: MockHTMLContentRecoverer(
                recoveredHTMLByMessageID: [
                    messageId: "<html><body><p>Recovered HTML body</p></body></html>"
                ]
            ),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let request = MessageBubbleContentRequest(
            messageID: messageId,
            bodyText: nil,
            chatPreviewText: nil,
            bodyStorageURI: nil,
            cleanedSnippet: "Stale stored preview",
            snippet: "Stale stored preview",
            subject: "Recovered preview",
            senderName: "Alice Example",
            hasHTMLSource: true,
            hasAttachments: false,
            isFromMe: false,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            effectiveSenderEmail: "alice@example.com",
            attachmentSnapshots: []
        )

        let first = await loader.loadContent(from: request)
        let second = await loader.loadContent(from: request)

        XCTAssertEqual(first.fullTextContent, "Recovered HTML body")
        XCTAssertEqual(second.fullTextContent, "Recovered HTML body")
    }

    func testLoadContent_incomingMessageKeepsStoredChatPreviewWhenRecoveryFindsHTML() async {
        let messageId = "bubble-recovered-preview-primary-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlContentRecoveryService: MockHTMLContentRecoverer(
                recoveredHTMLByMessageID: [
                    messageId: "<html><body><p>Recovered HTML body</p></body></html>"
                ]
            ),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let request = MessageBubbleContentRequest(
            messageID: messageId,
            bodyText: nil,
            chatPreviewText: "Stale stored preview",
            bodyStorageURI: nil,
            cleanedSnippet: "Stale stored preview",
            snippet: "Stale stored preview",
            subject: "Recovered preview",
            senderName: "Alice Example",
            hasHTMLSource: true,
            hasAttachments: false,
            isFromMe: false,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            effectiveSenderEmail: "alice@example.com",
            attachmentSnapshots: []
        )

        let first = await loader.loadContent(from: request)
        let second = await loader.loadContent(from: request)

        XCTAssertEqual(first.fullTextContent, "Stale stored preview")
        XCTAssertEqual(second.fullTextContent, "Stale stored preview")
    }

    func testLoadContent_storedChatPreviewClassifiesDirectHTMLBodyFallback() async {
        let messageId = "bubble-direct-html-rich-preview-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let directHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <section>
            <table role="presentation" width="100%">
              <tr><td><h1>Statement ready</h1></td></tr>
              <tr><td><p>Your monthly account statement is now available.</p></td></tr>
              <tr><td><a href="https://example.com/review">Review statement</a></td></tr>
            </table>
          </section>
        </body>
        </html>
        """

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: directHTML,
                chatPreviewText: "Statement ready",
                bodyStorageURI: nil,
                cleanedSnippet: "Statement ready",
                snippet: "Statement ready",
                subject: "Statement ready",
                senderName: "Example Bank",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alerts@examplebank.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Statement ready")
        XCTAssertTrue(result.hasRichHTMLContent)
        XCTAssertFalse(result.htmlAnalysis.hasHTMLSource)
    }

    func testLoadContent_storedChatPreviewCleansQuotesBeforeRichClassification() async {
        let messageId = "bubble-rich-quote-cleanup-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        _ = HTMLContentHandler.shared.saveHTML(
            """
            <!DOCTYPE html>
            <html>
            <body>
              <p>Sounds good to me.</p>
              <div class="gmail_quote">
                <section>
                  <table role="presentation" width="100%">
                    <tr><td><h1>Weekly newsletter</h1></td></tr>
                    <tr><td><p>\(String(repeating: "Quoted newsletter copy. ", count: 30))</p></td></tr>
                    <tr><td><a href="https://example.com/unsubscribe">Unsubscribe</a></td></tr>
                  </table>
                </section>
              </div>
            </body>
            </html>
            """,
            for: messageId
        )

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: nil,
                chatPreviewText: "Sounds good to me.",
                bodyStorageURI: nil,
                cleanedSnippet: "Sounds good to me.",
                snippet: "Sounds good to me.",
                subject: "Re: Weekly newsletter",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Sounds good to me.")
        XCTAssertFalse(result.hasRichHTMLContent)
    }

    func testLoadContent_rawEmailSourceWithEmbeddedHTML_marksRichContent() async {
        let messageId = "bubble-raw-html-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let rawSource = """
        Delivered-To: person@example.com
        Received: by 2002:a05:6e04:71a:b0:3ac:63b9:5e27 with SMTP id o26csp2106356imz;
        X-Received: by 2002:ac8:7dd4:0:b0:503:4257:da03 with SMTP id d75a77;
        Return-Path: <newsletter@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="newsletter-boundary-123"

        --newsletter-boundary-123
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        Example Museum
        View in Browser
        Tickets are now on sale for the Spring Documentary Festival
        Learn More
        Unsubscribe

        --newsletter-boundary-123
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        <!DOCTYPE html>
        <html>
        <body>
          <table role=3D"presentation" width=3D"100%">
            <tr>
              <td>
                <p>View in Browser</p>
                <h1>Tickets are now on sale for the Spring Documentary Festival</h1>
                <p>Join us for a showcase of outstanding documentary films and immersive conversations around the world.</p>
                <table role=3D"presentation">
                  <tr><td><a href=3D"https://example.com/learn-more">Learn More</a></td></tr>
                </table>
                <p><a href=3D"https://example.com/unsubscribe">Unsubscribe</a> | <a href=3D"https://example.com/preferences">Manage Preferences</a></p>
              </td>
            </tr>
          </table>
        </body>
        </html>

        --newsletter-boundary-123--
        """

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: rawSource,
                bodyStorageURI: nil,
                cleanedSnippet: "Tickets are now on sale for the Spring Documentary Festival",
                snippet: "Tickets are now on sale for the Spring Documentary Festival",
                subject: "Spring Documentary Festival",
                senderName: "Example Museum",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "newsletter@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertTrue(result.hasRichHTMLContent)
        XCTAssertTrue(result.fullTextContent?.contains("Tickets are now on sale for the Spring Documentary Festival") == true)
        XCTAssertFalse(result.htmlAnalysis.hasHTMLSource)
    }

    func testLoadContent_staleNewsletterFallbackText_recoversRichHTML() async throws {
        let messageId = "bubble-stale-fallback-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        await ProcessedTextCache.shared.set(
            messageId: messageId,
            plainText: """
            American Museum of Natural History
            https://e.wordfly.com/click?sid=abc123

            View in Browser
            https://e.wordfly.com/view?sid=abc123

            Manage Subscriptions
            https://e.wordfly.com/preferences?sid=abc123

            Privacy Policy
            https://e.wordfly.com/privacy?sid=abc123
            """,
            hasRichContent: false
        )

        let staleFallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-stale-fallback-\(UUID().uuidString).html")
        defer {
            try? FileManager.default.removeItem(at: staleFallbackURL)
        }

        try staleBubbleFallbackHTML.write(to: staleFallbackURL, atomically: true, encoding: .utf8)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlContentRecoveryService: MockHTMLContentRecoverer(
                recoveredHTMLByMessageID: [
                    messageId: """
                    <!DOCTYPE html>
                    <html>
                    <body>
                      <table role="presentation" width="100%">
                        <tr><td><h1>Tickets are now on sale for the 2026 Margaret Mead Film Festival</h1></td></tr>
                        <tr><td><p>View in Browser</p></td></tr>
                        <tr><td><p><a href="https://example.com/unsubscribe">Unsubscribe</a></p></td></tr>
                      </table>
                    </body>
                    </html>
                    """
                ]
            )
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                American Museum of Natural History
                https://e.wordfly.com/click?sid=abc123

                View in Browser
                https://e.wordfly.com/view?sid=abc123

                Manage Subscriptions
                https://e.wordfly.com/preferences?sid=abc123

                Privacy Policy
                https://e.wordfly.com/privacy?sid=abc123
                """,
                bodyStorageURI: staleFallbackURL.absoluteString,
                cleanedSnippet: "Tickets Now On Sale for the Margaret Mead Film Festival",
                snippet: "Tickets Now On Sale for the Margaret Mead Film Festival",
                subject: "Tickets Now On Sale",
                senderName: "American Museum of Natural History",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "publicprograms@email.amnh.org",
                attachmentSnapshots: []
            )
        )

        XCTAssertTrue(result.hasRichHTMLContent)
        XCTAssertTrue(result.fullTextContent?.contains("Tickets are now on sale for the 2026 Margaret Mead Film Festival") == true)
        XCTAssertTrue(result.htmlAnalysis.hasHTMLSource)
    }

    func testLoadContent_cachedEmptySourceFalseUsesCurrentNewsletterSnippetFallback() async throws {
        let messageId = "bubble-empty-source-newsletter-fallback-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)

        let sourceSignature = ProcessedTextCache.contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            handler: HTMLContentHandler.shared
        )
        XCTAssertEqual(sourceSignature, "empty")

        await ProcessedTextCache.shared.set(
            messageId: messageId,
            sourceSignature: sourceSignature,
            previewMode: ProcessedTextCache.chatBubblePreviewMode,
            plainText: "Ordinary cached preview",
            hasRichContent: false
        )

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlContentRecoveryService: MockHTMLContentRecoverer(
                recoveredHTMLByMessageID: [
                    messageId: """
                    <!DOCTYPE html>
                    <html>
                    <body>
                      <table role="presentation" width="100%">
                        <tr><td><h1>Recovered newsletter preview</h1></td></tr>
                        <tr><td><p>View in Browser</p></td></tr>
                        <tr><td><p><a href="https://example.com/unsubscribe">Unsubscribe</a></p></td></tr>
                      </table>
                    </body>
                    </html>
                    """
                ]
            ),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: nil,
                bodyStorageURI: nil,
                cleanedSnippet: "Tickets Now On Sale",
                snippet: """
                American Museum of Natural History
                https://e.wordfly.com/click?sid=abc123

                View in Browser
                https://e.wordfly.com/view?sid=abc123

                Manage Subscriptions
                https://e.wordfly.com/preferences?sid=abc123
                """,
                subject: "Tickets Now On Sale",
                senderName: "American Museum of Natural History",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "publicprograms@email.amnh.org",
                attachmentSnapshots: []
            )
        )

        XCTAssertTrue(result.hasRichHTMLContent)
        XCTAssertTrue(result.fullTextContent?.contains("Recovered newsletter preview") == true)
        XCTAssertTrue(result.htmlAnalysis.hasHTMLSource)

        await ProcessedTextCache.shared.invalidate(messageId: messageId)
    }

    func testLoadContent_outgoingForwardedMessage_returnsStructuredForwardPreview() async {
        let messageId = "bubble-forwarded-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                FYI

                ---------- Forwarded message ---------
                From: Jane Example &lt;jane@example.com&gt;
                Date: Mon, Feb 16, 2026 at 5:56 PM
                Subject: Spring plans
                To: me@example.com

                Looking forward to seeing you there.
                """,
                bodyStorageURI: nil,
                cleanedSnippet: "FYI",
                snippet: "FYI ---------- Forwarded message --------- From: Jane Example",
                subject: "Fwd: Spring plans",
                senderName: "Me",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "FYI")
        XCTAssertFalse(result.hasRichHTMLContent)
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Spring plans")
        XCTAssertEqual(
            result.forwardedDisplayContent?.previewSnippet,
            "Looking forward to seeing you there."
        )
        XCTAssertTrue(result.sharedDocumentLinks.isEmpty)
    }

    func testLoadContent_incomingForwardedMessage_returnsStructuredForwardPreview() async {
        let messageId = "bubble-incoming-forwarded-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                Sent from my iPhone.

                Begin forwarded message:

                From: Jane Example <jane@example.com>
                Date: Wed, Apr 22, 2026 at 8:12 AM
                To: Kevin Thau <kevin@example.com>
                Subject: Dinner reservation

                Your table is confirmed for 7:30 PM.
                """,
                bodyStorageURI: nil,
                cleanedSnippet: "Sent from my iPhone. Begin forwarded message:",
                snippet: "Sent from my iPhone. Begin forwarded message: From: Jane Example",
                subject: "Fwd: Dinner reservation",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Sent from my iPhone.")
        XCTAssertFalse(result.hasRichHTMLContent)
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result.forwardedDisplayContent?.senderEmail, "jane@example.com")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Dinner reservation")
        XCTAssertEqual(result.forwardedDisplayContent?.recipientSummary, "Kevin Thau")
        XCTAssertEqual(
            result.forwardedDisplayContent?.previewSnippet,
            "Your table is confirmed for 7:30 PM."
        )
        XCTAssertTrue(result.htmlAnalysis.hasHTMLSource)
    }

    func testLoadContent_incomingForwardedMessage_carriesFullForwardedBodyFromBodyText() async {
        let messageId = "bubble-incoming-forwarded-full-body-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                FYI

                ---------- Forwarded message ---------
                From: Brynn Example <brynn@example.com>
                Date: Sat, Aug 1, 2026 at 9:00 AM
                Subject: Weekend plans
                To: olga@example.com

                Hi Olga,

                Here is the first paragraph of the plan with all of the details we discussed.

                And here is a second paragraph that a 180-character preview snippet would have cut off entirely, including the closing question about whether Saturday afternoon still works.
                """,
                bodyStorageURI: nil,
                cleanedSnippet: "FYI",
                snippet: "FYI ---------- Forwarded message ---------",
                subject: "Fwd: Weekend plans",
                senderName: "Alice Example",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        let fullBodyText = result.forwardedDisplayContent?.fullBodyText ?? ""
        XCTAssertTrue(fullBodyText.contains("Hi Olga,"), "Unexpected body: \(fullBodyText)")
        XCTAssertTrue(
            fullBodyText.contains("whether Saturday afternoon still works"),
            "The transcript body must carry the entire forwarded message: \(fullBodyText)"
        )
    }

    func testLoadContent_incomingForwardedMessageWithOutlookHeaders_returnsStructuredForwardPreview() async {
        let messageId = "bubble-incoming-forwarded-outlook-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                FYI - Cargo received our motion today.

                From: Alex Dietrich <adietrich@example.com>
                Sent: Monday, June 15, 2026 3:46 PM
                To: KCargo <kcargo@example.com>
                Cc: Monica Mazzei <mmazzei@example.com>
                Subject: Thau - Respondent's RFO to Terminate

                Dear Counsel,

                Please use the Sharefile link below to access Respondent's Request for Order.
                """,
                bodyStorageURI: nil,
                cleanedSnippet: "FYI - Cargo received our motion today.",
                snippet: "FYI - Cargo received our motion today. From: Alex Dietrich",
                subject: "FW: Thau - Respondent's RFO to Terminate",
                senderName: "Monica Mazzei",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "monica@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "FYI - Cargo received our motion today.")
        XCTAssertFalse(result.hasRichHTMLContent)
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Alex Dietrich")
        XCTAssertEqual(result.forwardedDisplayContent?.senderEmail, "adietrich@example.com")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Thau - Respondent's RFO to Terminate")
        XCTAssertEqual(result.forwardedDisplayContent?.recipientSummary, "KCargo")
        XCTAssertEqual(
            result.forwardedDisplayContent?.previewSnippet,
            "Dear Counsel, Please use the Sharefile link below to access Respondent's Request for Order."
        )
        XCTAssertTrue(result.htmlAnalysis.hasHTMLSource)
    }

    func testLoadContent_forwardedMessagePrefersStructuredChatPreviewOverStaleBodyText() async {
        let messageId = "bubble-forwarded-chat-preview-primary-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                Stale body lead-in.

                Begin forwarded message:

                From: Stale Sender <stale@example.com>
                Date: Wed, Apr 22, 2026 at 8:12 AM
                Subject: Stale reservation

                Stale forwarded preview.
                """,
                chatPreviewText: """
                Canonical chat lead-in.

                Begin forwarded message:

                From: Jane Example <jane@example.com>
                Date: Wed, Apr 22, 2026 at 8:12 AM
                To: Kevin Thau <kevin@example.com>
                Subject: Dinner reservation

                Your table is confirmed for 7:30 PM.
                """,
                bodyStorageURI: nil,
                cleanedSnippet: "Stale body lead-in. Begin forwarded message:",
                snippet: "Stale body lead-in. Begin forwarded message: From: Stale Sender",
                subject: "Fwd: Dinner reservation",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Canonical chat lead-in.")
        XCTAssertEqual(result.forwardedDisplayContent?.leadInText, "Canonical chat lead-in.")
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result.forwardedDisplayContent?.senderEmail, "jane@example.com")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Dinner reservation")
        XCTAssertEqual(
            result.forwardedDisplayContent?.previewSnippet,
            "Your table is confirmed for 7:30 PM."
        )
    }

    func testLoadContent_forwardedMessageUsesChatPreviewLeadInWithBodyHeaderFallback() async {
        let messageId = "bubble-forwarded-chat-preview-lead-in-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                Stale raw lead-in.

                ---------- Forwarded message ---------
                From: Jane Example <jane@example.com>
                Date: Wed, Apr 22, 2026 at 8:12 AM
                Subject: Dinner reservation
                To: Kevin Thau <kevin@example.com>

                Your table is confirmed for 7:30 PM.
                """,
                chatPreviewText: "Canonical chat lead-in.",
                bodyStorageURI: nil,
                cleanedSnippet: "Stale raw lead-in. ---------- Forwarded message ---------",
                snippet: "Stale raw lead-in. ---------- Forwarded message --------- From: Jane Example",
                subject: "Fwd: Dinner reservation",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Canonical chat lead-in.")
        XCTAssertEqual(result.forwardedDisplayContent?.leadInText, "Canonical chat lead-in.")
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Dinner reservation")
        XCTAssertEqual(result.forwardedDisplayContent?.recipientSummary, "Kevin Thau")
    }

    func testLoadContent_forwardedMessageWithBlankChatPreviewUsesBodyTextFallback() async {
        let messageId = "bubble-forwarded-blank-chat-preview-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                Body fallback lead-in.

                ---------- Forwarded message ---------
                From: Jane Example <jane@example.com>
                Date: Wed, Apr 22, 2026 at 8:12 AM
                Subject: Dinner reservation

                Your table is confirmed for 7:30 PM.
                """,
                chatPreviewText: " \n\t ",
                bodyStorageURI: nil,
                cleanedSnippet: "Body fallback lead-in.",
                snippet: "Body fallback lead-in. ---------- Forwarded message --------- From: Jane Example",
                subject: "Fwd: Dinner reservation",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Body fallback lead-in.")
        XCTAssertEqual(result.forwardedDisplayContent?.leadInText, "Body fallback lead-in.")
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Dinner reservation")
    }

    func testLoadContent_forwardedMessageUsesCleanedSnippetBeforeSnippet() async {
        let messageId = "bubble-forwarded-cleaned-snippet-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: nil,
                bodyStorageURI: nil,
                cleanedSnippet: "FYI ---------- Forwarded message --------- From: Jane Example <jane@example.com> Date: Wed, Apr 22, 2026 at 8:12 AM Subject: Dinner reservation To: Kevin Thau <kevin@example.com> Your table is confirmed for 7:30 PM.",
                snippet: "FYI",
                subject: "Fwd: Dinner reservation",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "FYI")
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Dinner reservation")
        XCTAssertEqual(result.forwardedDisplayContent?.recipientSummary, "Kevin Thau")
        XCTAssertEqual(
            result.forwardedDisplayContent?.previewSnippet,
            "Your table is confirmed for 7:30 PM."
        )
    }

    func testLoadContent_forwardedMessageWithUnparseableBodyDoesNotProduceStructuredPreview() async {
        let messageId = "bubble-unparseable-forwarded-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: "Can you take a look at this?",
                bodyStorageURI: nil,
                cleanedSnippet: "Can you take a look at this?",
                snippet: "Can you take a look at this?",
                subject: "Fwd: Dinner reservation",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertNil(result.forwardedDisplayContent)
        XCTAssertEqual(result.fullTextContent, "Can you take a look at this?")
        XCTAssertTrue(result.htmlAnalysis.hasHTMLSource)
    }

    func testLoadContent_incomingUnparsedForwardedStoredPreviewClassifiesBodyFallbackHTML() async {
        let messageId = "bubble-unparsed-forwarded-rich-html-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        HTMLContentHandler.shared.deleteHTML(for: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                <!DOCTYPE html>
                <html>
                <body>
                  <section>
                    <table role="presentation" width="100%">
                      <tr><td><h1>Reserve your table</h1></td></tr>
                      <tr><td><p>Your reservation details are ready to review.</p></td></tr>
                      <tr><td><a href="https://example.com/review">Review details</a></td></tr>
                    </table>
                  </section>
                </body>
                </html>
                """,
                chatPreviewText: "Reservation details",
                bodyStorageURI: nil,
                cleanedSnippet: "Reservation details",
                snippet: "Reservation details",
                subject: "Fwd: Dinner reservation",
                senderName: "Alice Example",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertNil(result.forwardedDisplayContent)
        XCTAssertEqual(result.fullTextContent, "Reservation details")
        XCTAssertTrue(result.hasRichHTMLContent)
        XCTAssertFalse(result.htmlAnalysis.hasHTMLSource)
        XCTAssertTrue(
            MessageDisplayPolicy.shouldShowHTMLPreview(
                hasHTMLSource: result.htmlAnalysis.hasHTMLSource,
                isForwardedEmail: true,
                isNewsletter: false,
                hasRichHTMLContent: result.hasRichHTMLContent,
                isFromMe: false,
                isOneToOneConversation: true,
                subject: "Fwd: Dinner reservation",
                senderEmail: "alice@example.com"
            )
        )
    }

    func testLoadContent_outgoingReplyPrefersFullBodyOverStoredHTMLWhenChatPreviewMissing() async throws {
        let messageId = "bubble-outgoing-reply-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let htmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-outgoing-reply-\(UUID().uuidString).html")
        defer {
            try? FileManager.default.removeItem(at: htmlURL)
        }

        try "<html><body><p>Can we please see alts for:</p></body></html>"
            .write(to: htmlURL, atomically: true, encoding: .utf8)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let replyBody = """
        Can we please see alts for:

        Primary bedroom drapery
        Kitchen backsplash

        Thank you!

        On Tue, Jan 2, 2026 at 9:41 AM Alice Example <alice@example.com> wrote:
        > Original request that should stay out of the bubble.
        """

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: replyBody,
                bodyStorageURI: htmlURL.absoluteString,
                cleanedSnippet: "Can we please see alts for:",
                snippet: "Can we please see alts for:",
                subject: "Re: Finish options",
                senderName: "Me",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        let visibleText = try XCTUnwrap(result.fullTextContent)
        XCTAssertTrue(visibleText.contains("Can we please see alts for:\n\nPrimary bedroom drapery"))
        XCTAssertTrue(visibleText.contains("Kitchen backsplash"))
        XCTAssertTrue(visibleText.contains("Thank you!"))
        XCTAssertFalse(visibleText.contains("Original request that should stay out of the bubble."))
        XCTAssertNotEqual(visibleText, "Can we please see alts for:")
    }

    func testLoadContent_outgoingSnippetBodyKeepsLoadedHTMLText() async throws {
        let messageId = "bubble-outgoing-snippet-body-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let htmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-outgoing-snippet-body-\(UUID().uuidString).html")
        defer {
            try? FileManager.default.removeItem(at: htmlURL)
        }

        try """
        <html>
        <body>
          <p>Can we please see alts for:</p>
          <p>Primary bedroom drapery</p>
          <p>Kitchen backsplash</p>
          <p>Thank you!</p>
        </body>
        </html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: "Can we please see alts for:",
                bodyStorageURI: htmlURL.absoluteString,
                cleanedSnippet: "Can we please see alts for:",
                snippet: "Can we please see alts for:",
                subject: "Re: Finish options",
                senderName: "Me",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        let visibleText = try XCTUnwrap(result.fullTextContent)
        XCTAssertTrue(visibleText.contains("Can we please see alts for:"))
        XCTAssertTrue(visibleText.contains("Primary bedroom drapery"))
        XCTAssertTrue(visibleText.contains("Kitchen backsplash"))
        XCTAssertTrue(visibleText.contains("Thank you!"))
        XCTAssertNotEqual(visibleText, "Can we please see alts for:")
    }

    func testLoadContent_outgoingStoredChatPreviewWinsOverRicherBodyText() async throws {
        let messageId = "bubble-outgoing-chat-preview-comparison-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let replyBody = """
        Can we please see alts for:

        Primary bedroom drapery
        Kitchen backsplash
        """

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: replyBody,
                chatPreviewText: "Can we please see alts for:",
                bodyStorageURI: nil,
                cleanedSnippet: "Can we please see alts for:",
                snippet: "Can we please see alts for:",
                subject: "Re: Finish options",
                senderName: "Me",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Can we please see alts for:")
    }

    func testLoadContent_outgoingStoredChatPreviewWinsWhenBodyIsNotPrefixExpansion() async throws {
        let messageId = "bubble-outgoing-chat-preview-canonical-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                Different body text with more words than the canonical preview.

                On Tue, Jan 2, 2026 at 9:41 AM Alice Example <alice@example.com> wrote:
                > Quoted content that should not make the body win.
                """,
                chatPreviewText: "Canonical chat preview",
                bodyStorageURI: nil,
                cleanedSnippet: "Canonical chat preview",
                snippet: "Canonical chat preview",
                subject: "Re: Finish options",
                senderName: "Me",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Canonical chat preview")
    }

    func testLoadContent_outgoingStoredChatPreviewWinsOverTruncatedLoadedPrefix() async throws {
        let messageId = "bubble-outgoing-long-token-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let htmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-outgoing-long-token-\(UUID().uuidString).html")
        defer {
            try? FileManager.default.removeItem(at: htmlURL)
        }

        let fullURL = "https://example.com/shared/document/abcdefghijklmnopqrstuvwxyz"
        let truncatedURL = "https://example.com/shared/document/abc"
        try "<html><body><p>\(truncatedURL)</p></body></html>"
            .write(to: htmlURL, atomically: true, encoding: .utf8)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: "Runtime body should not replace the canonical preview.",
                chatPreviewText: fullURL,
                bodyStorageURI: htmlURL.absoluteString,
                cleanedSnippet: truncatedURL,
                snippet: truncatedURL,
                subject: "Shared link",
                senderName: "Me",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, fullURL)
    }

    func testLoadContent_outgoingLongSingleTokenBodyBeatsTruncatedLoadedPrefixWhenChatPreviewMissing() async throws {
        let messageId = "bubble-outgoing-long-token-no-preview-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let htmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-outgoing-long-token-no-preview-\(UUID().uuidString).html")
        defer {
            try? FileManager.default.removeItem(at: htmlURL)
        }

        let fullURL = "https://example.com/shared/document/abcdefghijklmnopqrstuvwxyz"
        let truncatedURL = "https://example.com/shared/document/abc"
        try "<html><body><p>\(truncatedURL)</p></body></html>"
            .write(to: htmlURL, atomically: true, encoding: .utf8)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: fullURL,
                bodyStorageURI: htmlURL.absoluteString,
                cleanedSnippet: truncatedURL,
                snippet: truncatedURL,
                subject: "Shared link",
                senderName: "Me",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, fullURL)
    }

    func testLoadContent_outgoingForwardedMessageWithoutLeadIn_avoidsRawSnippetFallback() async {
        let messageId = "bubble-forwarded-empty-note-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                ---------- Forwarded message ---------
                From: Jane Example &lt;jane@example.com&gt;
                Date: Mon, Feb 16, 2026 at 5:56 PM
                Subject: Spring plans

                Looking forward to seeing you there.
                """,
                bodyStorageURI: nil,
                cleanedSnippet: nil,
                snippet: "---------- Forwarded message --------- From: Jane Example",
                subject: "Fwd: Spring plans",
                senderName: "Me",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertNil(result.fullTextContent)
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(
            result.forwardedDisplayContent?.previewSnippet,
            "Looking forward to seeing you there."
        )
    }

    func testLoadContent_outgoingForwardedMessageSuppressesChatPreviewEchoFromForwardedBody() async {
        let messageId = "bubble-forwarded-echo-preview-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                ---------- Forwarded message ---------
                From: Park Avenue Armory &lt;news@armoryonpark.org&gt;
                Date: Jun 10, 2026 at 5:33 PM
                Subject: Now on View: Celeste Boursier-Mougenot's "clinamen"

                Experience the largest iteration of the aquatic and musical installation now through August 2.
                Additional support has been provided by the Armory's Artistic Council.
                """,
                chatPreviewText: "Additional support has been provided by the Armory's Artistic Council.",
                bodyStorageURI: nil,
                cleanedSnippet: "Additional support has been provided by the Armory's Artistic Council.",
                snippet: "Additional support has been provided by the Armory's Artistic Council.",
                subject: "Fwd: Now on View: Celeste Boursier-Mougenot's \"clinamen\"",
                senderName: "Me",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertNil(result.fullTextContent)
        XCTAssertNil(result.forwardedDisplayContent?.leadInText)
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Park Avenue Armory")
        XCTAssertEqual(
            result.forwardedDisplayContent?.previewSnippet,
            "Experience the largest iteration of the aquatic and musical installation now through August 2. Additional support has been provided by the Armory's Artistic Council."
        )
    }

    func testLoadContent_outgoingForwardedMessageKeepsTypedChatPreviewLeadIn() async {
        let messageId = "bubble-forwarded-typed-preview-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: """
                ---------- Forwarded message ---------
                From: Jane Example &lt;jane@example.com&gt;
                Date: Mon, Feb 16, 2026 at 5:56 PM
                Subject: Spring plans

                Looking forward to seeing you there.
                """,
                chatPreviewText: "Please see below.",
                bodyStorageURI: nil,
                cleanedSnippet: "Please see below.",
                snippet: "Please see below. ---------- Forwarded message ---------",
                subject: "Fwd: Spring plans",
                senderName: "Me",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "Please see below.")
        XCTAssertEqual(result.forwardedDisplayContent?.leadInText, "Please see below.")
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Spring plans")
    }

    func testLoadContent_outgoingForwardedMessageSnippetFallback_parsesFlattenedHeaders() async {
        let messageId = "bubble-forwarded-snippet-only-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: nil,
                bodyStorageURI: nil,
                cleanedSnippet: "FYI",
                snippet: "FYI ---------- Forwarded message --------- From: Jane Example <jane@example.com> Date: Mon, Feb 16, 2026 at 5:56 PM Subject: Spring plans To: me@example.com, friend@example.com Looking forward to seeing you there.",
                subject: "Fwd: Spring plans",
                senderName: "Me",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: true,
                isForwardedEmail: true,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "me@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertEqual(result.fullTextContent, "FYI")
        XCTAssertEqual(result.forwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result.forwardedDisplayContent?.subject, "Spring plans")
        XCTAssertEqual(result.forwardedDisplayContent?.recipientSummary, "me@example.com +1")
        XCTAssertEqual(
            result.forwardedDisplayContent?.previewSnippet,
            "Looking forward to seeing you there."
        )
    }

    func testLoadContent_resolvesHTMLAnalysisFromStoredHTMLSource() async throws {
        let messageId = "bubble-html-analysis-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)

        let htmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-html-analysis-\(UUID().uuidString).html")
        defer {
            try? FileManager.default.removeItem(at: htmlURL)
        }

        try """
        <!DOCTYPE html>
        <html>
        <body>
          <img src="cid:hero-image">
          <p>Hello world</p>
        </body>
        </html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        func makeRequest(hasAttachments: Bool) -> MessageBubbleContentRequest {
            MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: nil,
                bodyStorageURI: htmlURL.absoluteString,
                cleanedSnippet: "Hello world",
                snippet: "Hello world",
                subject: "Hello world",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: hasAttachments,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        }

        let placeholderResult = await loader.loadContent(
            from: makeRequest(hasAttachments: false)
        )
        XCTAssertTrue(placeholderResult.htmlAnalysis.hasHTMLSource)
        XCTAssertEqual(placeholderResult.htmlAnalysis.referencedInlineContentIDs, [])

        let result = await loader.loadContent(
            from: makeRequest(hasAttachments: true)
        )

        XCTAssertTrue(result.htmlAnalysis.hasHTMLSource)
        XCTAssertEqual(result.htmlAnalysis.referencedInlineContentIDs, ["hero-image"])
    }

    func testHTMLAnalysisBuilder_detectsInlineContentIDsInSrcsetOnlyMarkup() {
        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: """
            <html>
            <body>
              <picture>
                <source srcset="cid:hero-image 1x, cid:hero-image-2x 2x">
                <img alt="Hero image">
              </picture>
            </body>
            </html>
            """,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: nil,
            subject: nil,
            attachmentSnapshots: []
        )

        XCTAssertEqual(
            analysis.referencedInlineContentIDs,
            ["hero-image", "hero-image-2x"]
        )
    }

    func testLoadContent_sourceSignatureRefreshesProcessedTextWhenStoredHTMLChanges() async throws {
        let messageId = "bubble-source-refresh-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        _ = HTMLContentHandler.shared.saveHTML(
            "<html><body><p>FIRST_BODY_TOKEN</p></body></html>",
            for: messageId
        )

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:])
        )

        func makeRequest() -> MessageBubbleContentRequest {
            MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: nil,
                chatPreviewText: nil,
                bodyStorageURI: nil,
                cleanedSnippet: nil,
                snippet: nil,
                subject: "Source refresh",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        }

        let first = await loader.loadContent(from: makeRequest())

        _ = HTMLContentHandler.shared.saveHTML(
            "<html><body><p>SECOND_BODY_TOKEN</p></body></html>",
            for: messageId
        )

        let second = await loader.loadContent(from: makeRequest())

        XCTAssertTrue(first.fullTextContent?.contains("FIRST_BODY_TOKEN") == true)
        XCTAssertFalse(first.fullTextContent?.contains("SECOND_BODY_TOKEN") == true)
        XCTAssertTrue(second.fullTextContent?.contains("SECOND_BODY_TOKEN") == true)
        XCTAssertFalse(second.fullTextContent?.contains("FIRST_BODY_TOKEN") == true)
    }

    func testLoadContent_emptyStoredHTMLKeysBodyFallbackByBodyText() async throws {
        let messageId = "bubble-empty-html-body-fallback-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        _ = HTMLContentHandler.shared.saveHTML(
            "<html><body><img src=\"cid:hero-image\"></body></html>",
            for: messageId
        )

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        func makeRequest(bodyText: String) -> MessageBubbleContentRequest {
            MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: bodyText,
                bodyStorageURI: nil,
                cleanedSnippet: bodyText,
                snippet: bodyText,
                subject: "Fallback body",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        }

        let first = await loader.loadContent(from: makeRequest(bodyText: "FIRST_BODY_TOKEN"))
        let second = await loader.loadContent(from: makeRequest(bodyText: "SECOND_BODY_TOKEN"))

        XCTAssertEqual(first.fullTextContent, "FIRST_BODY_TOKEN")
        XCTAssertEqual(second.fullTextContent, "SECOND_BODY_TOKEN")

        await ProcessedTextCache.shared.invalidate(messageId: messageId)
    }

    func testLoadContent_cachedRichHTMLWithoutTextIsPreservedOverBodyFallback() async throws {
        let messageId = "bubble-rich-html-cache-\(UUID().uuidString)"
        await ProcessedTextCache.shared.invalidate(messageId: messageId)
        defer {
            HTMLContentHandler.shared.deleteHTML(for: messageId)
        }

        _ = HTMLContentHandler.shared.saveHTML(
            "<html><body><iframe src=\"https://example.com/embed\"></iframe></body></html>",
            for: messageId
        )

        let sourceSignature = ProcessedTextCache.contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: nil,
            handler: HTMLContentHandler.shared
        )
        await ProcessedTextCache.shared.set(
            messageId: messageId,
            sourceSignature: sourceSignature,
            previewMode: ProcessedTextCache.chatBubblePreviewMode,
            plainText: nil,
            hasRichContent: true
        )

        let loader = MessageBubbleLoader(
            contactsResolver: MockBubbleContactsResolver(contactMap: [:]),
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache()
        )

        let result = await loader.loadContent(
            from: MessageBubbleContentRequest(
                messageID: messageId,
                bodyText: "Fallback body text",
                bodyStorageURI: nil,
                cleanedSnippet: "Fallback body text",
                snippet: "Fallback body text",
                subject: "Embedded media",
                senderName: "Alice Example",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: "alice@example.com",
                attachmentSnapshots: []
            )
        )

        XCTAssertNil(result.fullTextContent)
        XCTAssertTrue(result.hasRichHTMLContent)
        XCTAssertTrue(result.htmlAnalysis.hasHTMLSource)

        await ProcessedTextCache.shared.invalidate(messageId: messageId)
    }
}

private final class MockBubbleContactsResolver: ContactsResolving, @unchecked Sendable {
    private let contactMap: [String: ContactMatch]

    init(contactMap: [String: ContactMatch]) {
        self.contactMap = contactMap
    }

    func ensureAuthorization() async throws {}

    func lookup(email: String) async -> ContactMatch? {
        let normalizedEmail = EmailNormalizer.normalize(email)
        return contactMap[normalizedEmail] ?? contactMap[email]
    }

    func prewarm(emails: [String]) async {}
}

private struct MockHTMLContentRecoverer: HTMLContentRecovering {
    let recoveredHTMLByMessageID: [String: String]

    func recoverHTMLContent(messageId: String) async -> String? {
        recoveredHTMLByMessageID[messageId]
    }
}

private actor CountingHTMLContentRecoverer: HTMLContentRecovering {
    let recoveredHTMLByMessageID: [String: String]
    private var callCount = 0

    init(recoveredHTMLByMessageID: [String: String]) {
        self.recoveredHTMLByMessageID = recoveredHTMLByMessageID
    }

    func recoverHTMLContent(messageId: String) async -> String? {
        callCount += 1
        return recoveredHTMLByMessageID[messageId]
    }

    func recoveryCallCount() -> Int {
        callCount
    }
}

private let staleBubbleFallbackHTML = """
<!DOCTYPE html>
<html>
<head>
  <style id="esc-plain-text-styles">
    .esc-plain-main { white-space: pre-wrap; }
  </style>
</head>
<body>
  <div class="esc-plain-main">American Museum of Natural History</div>
  <details class="esc-plain-details">
    <summary>See More</summary>
    <div class="esc-plain-quotes">Tracked links and collapsed newsletter body</div>
  </details>
</body>
</html>
"""
