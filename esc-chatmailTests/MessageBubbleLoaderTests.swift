import XCTest
@testable import esc_chatmail

final class MessageBubbleLoaderTests: XCTestCase {
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
                personDisplayName: "Header Alias",
                personAvatarURL: nil
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
                snippet: "Tickets are now on sale for the Spring Documentary Festival",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                effectiveSenderEmail: "newsletter@example.com"
            )
        )

        XCTAssertTrue(result.hasRichHTMLContent)
        XCTAssertTrue(result.fullTextContent?.contains("Tickets are now on sale for the Spring Documentary Festival") == true)
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
                snippet: "Tickets Now On Sale for the Margaret Mead Film Festival",
                hasHTMLSource: true,
                hasAttachments: false,
                isFromMe: false,
                effectiveSenderEmail: "publicprograms@email.amnh.org"
            )
        )

        XCTAssertTrue(result.hasRichHTMLContent)
        XCTAssertTrue(result.fullTextContent?.contains("Tickets are now on sale for the 2026 Margaret Mead Film Festival") == true)
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
