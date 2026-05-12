import XCTest
@testable import esc_chatmail

final class MessageBubbleLoaderTests: XCTestCase {
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

    func testLoadContent_outgoingReplyPrefersFullBodyOverSnippetAndStoredHTML() async throws {
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

    func testLoadContent_outgoingLongSingleTokenBodyBeatsTruncatedPrefix() async throws {
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
