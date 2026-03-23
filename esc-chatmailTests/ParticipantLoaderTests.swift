import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ParticipantLoaderTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    func testExtractNonMeParticipants_excludesHideMyEmailRelay() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("San, Hide")
            .build(in: context)

        let sender = PersonBuilder()
            .withEmail("tickets@sfballet.org")
            .withDisplayName("San Francisco Ballet")
            .build(in: context)

        let hideRelay = PersonBuilder()
            .withEmail("thud-others-1n@icloud.com")
            .withDisplayName("Hide My Email")
            .build(in: context)

        let me = PersonBuilder()
            .withEmail("kmthau@gmail.com")
            .withDisplayName("Kevin Thau")
            .build(in: context)

        addConversationParticipant(person: sender, to: conversation)
        addConversationParticipant(person: hideRelay, to: conversation)
        addConversationParticipant(person: me, to: conversation)
        try context.save()

        let emails = ParticipantLoader.shared.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: "kmthau@gmail.com"
        )

        XCTAssertEqual(emails, ["tickets@sfballet.org"])
    }

    func testLoadParticipants_deletedConversationObjectID_returnsFallback() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback Name")
            .build(in: context)
        try context.save()

        let conversationObjectID = conversation.objectID
        context.delete(conversation)
        try context.save()

        let info = await ParticipantLoader.shared.loadParticipants(
            from: conversationObjectID,
            in: context,
            currentUserEmail: "kmthau@gmail.com",
            maxParticipants: 4,
            fallbackDisplayName: "Fallback Name"
        )

        XCTAssertEqual(info.emails, [])
        XCTAssertEqual(info.displayNames, [])
        XCTAssertEqual(info.photos.count, 0)
        XCTAssertEqual(info.formattedDisplayName, "Fallback Name")
        XCTAssertEqual(info.totalUniqueParticipants, 0)
    }

    // MARK: - Contact Deduplication Tests

    func testLoadParticipants_deduplicatesByContactIdentifier() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Test")
            .build(in: context)

        let workEmail = PersonBuilder()
            .withEmail("john@work.com")
            .withDisplayName("John Work")
            .build(in: context)

        let personalEmail = PersonBuilder()
            .withEmail("john@personal.com")
            .withDisplayName("John Personal")
            .build(in: context)

        addConversationParticipant(person: workEmail, to: conversation)
        addConversationParticipant(person: personalEmail, to: conversation)
        try context.save()

        // Both emails map to the same contact identifier
        let mockResolver = MockContactsResolving(contactMap: [
            "john@work.com": ContactMatch(displayName: "John Smith", email: "john@work.com", imageData: nil, contactIdentifier: "contact-123"),
            "john@personal.com": ContactMatch(displayName: "John Smith", email: "john@personal.com", imageData: nil, contactIdentifier: "contact-123")
        ])

        let loader = ParticipantLoader(contactsResolver: mockResolver)

        let info = await loader.loadParticipants(
            from: conversation,
            currentUserEmail: "me@example.com"
        )

        // Should only show one participant since both emails belong to the same contact
        XCTAssertEqual(info.emails.count, 1)
        XCTAssertEqual(info.emails.first, "john@work.com")
        XCTAssertEqual(info.totalUniqueParticipants, 1)
    }

    func testLoadParticipants_keepsSeparateParticipantsForDifferentContacts() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Test")
            .build(in: context)

        let alice = PersonBuilder()
            .withEmail("alice@example.com")
            .withDisplayName("Alice")
            .build(in: context)

        let bob = PersonBuilder()
            .withEmail("bob@example.com")
            .withDisplayName("Bob")
            .build(in: context)

        addConversationParticipant(person: alice, to: conversation)
        addConversationParticipant(person: bob, to: conversation)
        try context.save()

        let mockResolver = MockContactsResolving(contactMap: [
            "alice@example.com": ContactMatch(displayName: "Alice", email: "alice@example.com", imageData: nil, contactIdentifier: "contact-alice"),
            "bob@example.com": ContactMatch(displayName: "Bob", email: "bob@example.com", imageData: nil, contactIdentifier: "contact-bob")
        ])

        let loader = ParticipantLoader(contactsResolver: mockResolver)

        let info = await loader.loadParticipants(
            from: conversation,
            currentUserEmail: "me@example.com"
        )

        XCTAssertEqual(info.emails.count, 2)
        XCTAssertEqual(info.totalUniqueParticipants, 2)
    }

    func testLoadParticipants_keepsEmailsWithNoMatchingContact() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Test")
            .build(in: context)

        let known = PersonBuilder()
            .withEmail("known@example.com")
            .withDisplayName("Known")
            .build(in: context)

        let unknown = PersonBuilder()
            .withEmail("unknown@example.com")
            .withDisplayName("Unknown")
            .build(in: context)

        addConversationParticipant(person: known, to: conversation)
        addConversationParticipant(person: unknown, to: conversation)
        try context.save()

        // Only one email has a contact match; the other returns nil
        let mockResolver = MockContactsResolving(contactMap: [
            "known@example.com": ContactMatch(displayName: "Known Person", email: "known@example.com", imageData: nil, contactIdentifier: "contact-1")
        ])

        let loader = ParticipantLoader(contactsResolver: mockResolver)

        let info = await loader.loadParticipants(
            from: conversation,
            currentUserEmail: "me@example.com"
        )

        // Both should be kept since unknown has no contact to deduplicate against
        XCTAssertEqual(info.emails.count, 2)
        XCTAssertEqual(info.totalUniqueParticipants, 2)
    }

    func testSenderGroupingKeys_collapseEmailsForSameContact() async {
        let mockResolver = MockContactsResolving(contactMap: [
            "john@work.com": ContactMatch(displayName: "John Smith", email: "john@work.com", imageData: nil, contactIdentifier: "contact-123"),
            "john@personal.com": ContactMatch(displayName: "John Smith", email: "john@personal.com", imageData: nil, contactIdentifier: "contact-123")
        ])

        let loader = ParticipantLoader(contactsResolver: mockResolver)

        let groupingKeys = await loader.senderGroupingKeys(for: [
            "john@work.com",
            "john@personal.com"
        ])

        XCTAssertEqual(groupingKeys[EmailNormalizer.normalize("john@work.com")], "contact:contact-123")
        XCTAssertEqual(groupingKeys[EmailNormalizer.normalize("john@personal.com")], "contact:contact-123")
    }

    func testSenderGroupingKeys_keepDistinctContactsSeparate() async {
        let mockResolver = MockContactsResolving(contactMap: [
            "alice@example.com": ContactMatch(displayName: "Alice", email: "alice@example.com", imageData: nil, contactIdentifier: "contact-alice"),
            "bob@example.com": ContactMatch(displayName: "Bob", email: "bob@example.com", imageData: nil, contactIdentifier: "contact-bob")
        ])

        let loader = ParticipantLoader(contactsResolver: mockResolver)

        let groupingKeys = await loader.senderGroupingKeys(for: [
            "alice@example.com",
            "bob@example.com"
        ])

        XCTAssertEqual(groupingKeys[EmailNormalizer.normalize("alice@example.com")], "contact:contact-alice")
        XCTAssertEqual(groupingKeys[EmailNormalizer.normalize("bob@example.com")], "contact:contact-bob")
    }

    // MARK: - Helpers

    private func addConversationParticipant(person: Person, to conversation: Conversation) {
        let participant = ConversationParticipant(context: context)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation
    }
}

// MARK: - Mock ContactsResolving

private final class MockContactsResolving: ContactsResolving, @unchecked Sendable {
    private let contactMap: [String: ContactMatch]

    init(contactMap: [String: ContactMatch] = [:]) {
        self.contactMap = contactMap
    }

    func ensureAuthorization() async throws {}

    func lookup(email: String) async -> ContactMatch? {
        let normalized = EmailNormalizer.normalize(email)
        return contactMap[normalized] ?? contactMap[email]
    }

    func prewarm(emails: [String]) async {}
}
