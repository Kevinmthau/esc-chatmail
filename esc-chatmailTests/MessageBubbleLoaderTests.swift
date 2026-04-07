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
