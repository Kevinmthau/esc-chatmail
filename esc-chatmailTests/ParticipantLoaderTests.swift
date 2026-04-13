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

    func testLoadParticipants_prefersContactDisplayNameForSingleParticipant() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback")
            .build(in: context)

        let participant = PersonBuilder()
            .withEmail("single-priority@example.com")
            .withDisplayName("Header Alias")
            .build(in: context)

        addConversationParticipant(person: participant, to: conversation)
        try context.save()

        let loader = ParticipantLoader(contactsResolver: MockContactsResolving(contactMap: [
            "single-priority@example.com": ContactMatch(
                displayName: "Address Book Name",
                email: "single-priority@example.com",
                imageData: nil,
                contactIdentifier: "contact-single"
            )
        ]))

        let info = await loader.loadParticipants(
            from: conversation,
            currentUserEmail: "me@example.com"
        )

        XCTAssertEqual(info.displayNames, ["Address Book Name"])
        XCTAssertEqual(info.formattedDisplayName, "Address Book Name")
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
        XCTAssertTrue([
            "john@work.com",
            "john@personal.com"
        ].contains(info.emails.first))
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

    func testResolveParticipants_deduplicatesParticipantsListByContactIdentifier() async {
        let mockResolver = MockContactsResolving(contactMap: [
            "john@work.com": ContactMatch(displayName: "John Smith", email: "john@work.com", imageData: nil, contactIdentifier: "contact-123"),
            "john@personal.com": ContactMatch(displayName: "John Smith", email: "john@personal.com", imageData: nil, contactIdentifier: "contact-123")
        ])

        let loader = ParticipantLoader(contactsResolver: mockResolver)

        let resolvedParticipants = await loader.resolveParticipants(for: [
            "john@work.com",
            "john@personal.com"
        ])

        XCTAssertEqual(resolvedParticipants.count, 1)
        XCTAssertEqual(resolvedParticipants.first?.email, "john@work.com")
        XCTAssertEqual(resolvedParticipants.first?.displayName, "John Smith")
        XCTAssertEqual(resolvedParticipants.first?.contactIdentifier, "contact-123")
    }

    func testLoadParticipants_usesCachedRollupForRepeatedLoadsOfUnchangedConversation() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback Name")
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail("friend@example.com")
            .withDisplayName("Header Friend")
            .build(in: context)

        addConversationParticipant(person: friend, to: conversation)
        try context.save()

        let dependencyTracker = ParticipantRollupDependencyTracker()
        let contactsResolver = CountingContactsResolving(contactMap: [
            "friend@example.com": ContactMatch(
                displayName: "Address Book Friend",
                email: "friend@example.com",
                imageData: nil,
                contactIdentifier: "contact-friend"
            )
        ])
        let photoCounter = Counter()
        let loader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { emails in
                photoCounter.increment()
                return emails.map { _ in
                    ProfilePhoto(source: .cached, imageData: nil, url: "file:///tmp/avatar.jpg")
                }
            },
            rollupDependencyTracker: dependencyTracker
        )

        let first = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName
        )
        let second = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName
        )

        XCTAssertEqual(first.formattedDisplayName, "Address Book Friend")
        XCTAssertEqual(second.formattedDisplayName, first.formattedDisplayName)
        XCTAssertEqual(second.displayNames, first.displayNames)
        XCTAssertEqual(second.emails, first.emails)
        XCTAssertEqual(contactsResolver.lookupCount, 1)
        XCTAssertEqual(photoCounter.count, 1)
    }

    func testLoadParticipants_invalidatesWhenParticipantMembershipChanges() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback Name")
            .withParticipantHash(calculateParticipantHash(from: ["alice@example.com"]))
            .build(in: context)

        let alice = PersonBuilder()
            .withEmail("alice@example.com")
            .withDisplayName("Alice Header")
            .build(in: context)

        addConversationParticipant(person: alice, to: conversation)
        try context.save()

        let dependencyTracker = ParticipantRollupDependencyTracker()
        let contactsResolver = CountingContactsResolving(contactMap: [
            "alice@example.com": ContactMatch(displayName: "Alice", email: "alice@example.com", imageData: nil, contactIdentifier: "contact-alice"),
            "bob@example.com": ContactMatch(displayName: "Bob", email: "bob@example.com", imageData: nil, contactIdentifier: "contact-bob")
        ])
        let loader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: dependencyTracker
        )

        _ = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        let bob = PersonBuilder()
            .withEmail("bob@example.com")
            .withDisplayName("Bob Header")
            .build(in: context)

        addConversationParticipant(person: bob, to: conversation)
        conversation.participantHash = calculateParticipantHash(from: ["alice@example.com", "bob@example.com"])
        try context.save()

        let updated = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(updated.totalUniqueParticipants, 2)
        XCTAssertEqual(Set(updated.displayNames), ["Alice", "Bob"])
        XCTAssertEqual(contactsResolver.lookupCount, 3)
    }

    func testLoadParticipants_invalidatesWhenFallbackDisplayNameChanges() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Old Fallback")
            .withParticipantHash(calculateParticipantHash(from: ["me@example.com"]))
            .build(in: context)
        try context.save()

        let loader = ParticipantLoader(
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let initial = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        conversation.displayName = "New Fallback"
        try context.save()

        let updated = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(initial.formattedDisplayName, "Old Fallback")
        XCTAssertEqual(updated.formattedDisplayName, "New Fallback")
    }

    func testLoadParticipants_doesNotInvalidateForUnrelatedConversationChanges() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback Name")
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .withSnippet("before")
            .withUnreadCount(1)
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail("friend@example.com")
            .withDisplayName("Header Friend")
            .build(in: context)

        addConversationParticipant(person: friend, to: conversation)
        try context.save()

        let dependencyTracker = ParticipantRollupDependencyTracker()
        let contactsResolver = CountingContactsResolving(contactMap: [
            "friend@example.com": ContactMatch(
                displayName: "Address Book Friend",
                email: "friend@example.com",
                imageData: nil,
                contactIdentifier: "contact-friend"
            )
        ])
        let loader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: dependencyTracker
        )

        _ = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        conversation.snippet = "after"
        conversation.inboxUnreadCount = 4
        conversation.pinned = true
        try context.save()

        let cached = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(cached.formattedDisplayName, "Address Book Friend")
        XCTAssertEqual(contactsResolver.lookupCount, 1)
    }

    func testLoadParticipants_includePhotosFalseStaysCheapAndPhotoUpgradeReusesBaseRollup() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback Name")
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail("friend@example.com")
            .withDisplayName("Header Friend")
            .build(in: context)

        addConversationParticipant(person: friend, to: conversation)
        try context.save()

        let dependencyTracker = ParticipantRollupDependencyTracker()
        let contactsResolver = CountingContactsResolving(contactMap: [
            "friend@example.com": ContactMatch(
                displayName: "Address Book Friend",
                email: "friend@example.com",
                imageData: nil,
                contactIdentifier: "contact-friend"
            )
        ])
        let photoCounter = Counter()
        let loader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { emails in
                photoCounter.increment()
                return emails.map { _ in
                    ProfilePhoto(source: .cached, imageData: nil, url: "file:///tmp/avatar.jpg")
                }
            },
            rollupDependencyTracker: dependencyTracker
        )

        let noPhotos = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )
        let cachedNoPhotos = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )
        let withPhotos = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: true
        )
        let cachedWithPhotos = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: true
        )

        XCTAssertEqual(noPhotos.photos.count, 0)
        XCTAssertEqual(cachedNoPhotos.photos.count, 0)
        XCTAssertEqual(withPhotos.photos.count, 1)
        XCTAssertEqual(cachedWithPhotos.photos.count, 1)
        XCTAssertEqual(contactsResolver.lookupCount, 1)
        XCTAssertEqual(photoCounter.count, 1)
    }

    func testLoadParticipants_invalidatesCachedRollupWhenParticipantDependencyChanges() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback Name")
            .withParticipantHash(calculateParticipantHash(from: ["friend@example.com"]))
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail("friend@example.com")
            .withDisplayName("Header Friend")
            .build(in: context)

        addConversationParticipant(person: friend, to: conversation)
        try context.save()

        let dependencyTracker = ParticipantRollupDependencyTracker()
        let contactsResolver = CountingContactsResolving(contactMap: [
            "friend@example.com": ContactMatch(
                displayName: "Address Book Friend",
                email: "friend@example.com",
                imageData: nil,
                contactIdentifier: "contact-friend"
            )
        ])
        let loader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: dependencyTracker
        )

        _ = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        dependencyTracker.invalidate(email: "friend@example.com")

        _ = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(contactsResolver.lookupCount, 2)
    }

    func testLoadParticipants_cachedRollupPreservesDeduplicatedContactBehavior() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback Name")
            .withParticipantHash(calculateParticipantHash(from: ["john@personal.com", "john@work.com"]))
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

        let contactsResolver = CountingContactsResolving(contactMap: [
            "john@work.com": ContactMatch(displayName: "John Smith", email: "john@work.com", imageData: nil, contactIdentifier: "contact-123"),
            "john@personal.com": ContactMatch(displayName: "John Smith", email: "john@personal.com", imageData: nil, contactIdentifier: "contact-123")
        ])
        let loader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let first = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )
        let second = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(first.emails.count, 1)
        XCTAssertEqual(first.totalUniqueParticipants, 1)
        XCTAssertEqual(second.emails, first.emails)
        XCTAssertEqual(second.totalUniqueParticipants, 1)
        XCTAssertEqual(contactsResolver.lookupCount, 2)
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

private final class CountingContactsResolving: ContactsResolving, @unchecked Sendable {
    private let contactMap: [String: ContactMatch]
    private let lock = NSLock()
    private var _lookupCount = 0

    init(contactMap: [String: ContactMatch] = [:]) {
        self.contactMap = contactMap
    }

    var lookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _lookupCount
    }

    func ensureAuthorization() async throws {}

    func lookup(email: String) async -> ContactMatch? {
        let normalized = EmailNormalizer.normalize(email)

        lock.lock()
        _lookupCount += 1
        lock.unlock()

        return contactMap[normalized] ?? contactMap[email]
    }

    func prewarm(emails: [String]) async {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func increment() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}
