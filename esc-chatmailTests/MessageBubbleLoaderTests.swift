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
