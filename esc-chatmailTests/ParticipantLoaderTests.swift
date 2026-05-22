import XCTest
import CoreData
import Contacts
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

    func testLoadParticipants_excludesSelfAliasesFromUniqueParticipantCount() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Friend, Kevin")
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail("friend@example.com")
            .withDisplayName("Friend")
            .build(in: context)

        let meGmail = PersonBuilder()
            .withEmail("kmthau@gmail.com")
            .withDisplayName("Kevin Thau")
            .build(in: context)

        let meICloud = PersonBuilder()
            .withEmail("kthau@me.com")
            .withDisplayName("Kevin Thau")
            .build(in: context)

        addConversationParticipant(person: friend, to: conversation)
        addConversationParticipant(person: meGmail, to: conversation)
        addConversationParticipant(person: meICloud, to: conversation)
        _ = MessageBuilder()
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        let loader = ParticipantLoader(
            contactsResolver: MockContactsResolving(contactMap: [:]),
            currentUserAliasesProvider: { _, _ in
                ["kmthau@gmail.com", "kthau@me.com"]
            },
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let info = await loader.loadParticipants(
            from: conversation,
            currentUserEmail: "kmthau@gmail.com",
            includePhotos: false
        )

        XCTAssertEqual(info.emails, ["friend@example.com"])
        XCTAssertEqual(info.totalUniqueParticipants, 1)
        XCTAssertEqual(info.formattedDisplayName, "Friend")
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
            currentUserEmail: "me@example.com",
            includePhotos: false
        )

        XCTAssertEqual(info.displayNames, ["Address Book Name"])
        XCTAssertEqual(info.formattedDisplayName, "Address Book Name")
    }

    func testLoadParticipants_noRealNameUsesUnknownContact() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John Smith")
            .build(in: context)

        let participant = PersonBuilder()
            .withEmail("john.smith@example.com")
            .withDisplayName("John Smith")
            .build(in: context)

        addConversationParticipant(person: participant, to: conversation)
        try context.save()

        let loader = ParticipantLoader(
            contactsResolver: MockContactsResolving(contactMap: [:]),
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let info = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(info.displayNames, [])
        XCTAssertEqual(info.formattedDisplayName, "Unknown Contact")
    }

    func testLoadParticipants_preservesExplicitHeaderNameWhenStoredNameLooksAddressDerived() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John Smith")
            .withParticipantHash(calculateParticipantHash(from: ["john.smith@example.com"]))
            .build(in: context)

        let participant = PersonBuilder()
            .withEmail("john.smith@example.com")
            .withDisplayName("John Smith")
            .build(in: context)

        addConversationParticipant(person: participant, to: conversation)
        _ = MessageBuilder()
            .withSender(email: "john.smith@example.com", name: "John Smith")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        let contactsResolver = CountingContactsResolving(contactMap: [:])
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
        let cached = loader.cachedParticipantInfo(
            conversationObjectID: conversation.objectID,
            participantHash: conversation.participantHash,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
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

        XCTAssertEqual(first.displayNames, ["John Smith"])
        XCTAssertEqual(first.formattedDisplayName, "John Smith")
        XCTAssertEqual(cached?.displayNames, ["John Smith"])
        XCTAssertEqual(cached?.formattedDisplayName, "John Smith")
        XCTAssertEqual(second.displayNames, ["John Smith"])
        XCTAssertEqual(second.formattedDisplayName, "John Smith")
        XCTAssertEqual(contactsResolver.lookupCount, 1)
    }

    func testLoadParticipants_preservesExplicitBrandNameMatchingEmailLocalPart() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .withParticipantHash(calculateParticipantHash(from: ["a16z@substack.com"]))
            .build(in: context)

        let participant = PersonBuilder()
            .withEmail("a16z@substack.com")
            .withDisplayName("a16z")
            .build(in: context)

        addConversationParticipant(person: participant, to: conversation)
        _ = MessageBuilder()
            .withSender(email: "a16z@substack.com", name: "a16z")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        let loader = ParticipantLoader(
            contactsResolver: MockContactsResolving(contactMap: [:]),
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let info = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(info.displayNames, ["a16z"])
        XCTAssertEqual(info.formattedDisplayName, "a16z")
    }

    func testLoadParticipants_usesStoredNameWhenHeaderIsPlainRawLocalPart() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Unknown Contact")
            .withParticipantHash(calculateParticipantHash(from: ["john@example.com"]))
            .build(in: context)

        let participant = PersonBuilder()
            .withEmail("john@example.com")
            .withDisplayName("John Appleseed")
            .build(in: context)

        addConversationParticipant(person: participant, to: conversation)
        _ = MessageBuilder()
            .withSender(email: "john@example.com", name: "john")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        let loader = ParticipantLoader(
            contactsResolver: MockContactsResolving(contactMap: [:]),
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let info = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(info.displayNames, ["John Appleseed"])
        XCTAssertEqual(info.formattedDisplayName, "John Appleseed")
    }

    func testLoadParticipants_omitsExplicitRawLocalPartWithSeparator() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John Smith")
            .withParticipantHash(calculateParticipantHash(from: ["john.smith@example.com"]))
            .build(in: context)

        let participant = PersonBuilder()
            .withEmail("john.smith@example.com")
            .withDisplayName("John Smith")
            .build(in: context)

        addConversationParticipant(person: participant, to: conversation)
        _ = MessageBuilder()
            .withSender(email: "john.smith@example.com", name: "john.smith")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        let loader = ParticipantLoader(
            contactsResolver: MockContactsResolving(contactMap: [:]),
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let info = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(info.displayNames, [])
        XCTAssertEqual(info.formattedDisplayName, "Unknown Contact")
    }

    func testLoadParticipants_doesNotCacheHeaderOnlyNameAfterHeaderRemoved() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John Smith")
            .build(in: context)

        let participant = PersonBuilder()
            .withEmail("john.smith@example.com")
            .withDisplayName("John Smith")
            .build(in: context)

        addConversationParticipant(person: participant, to: conversation)
        let message = MessageBuilder()
            .withSender(email: "john.smith@example.com", name: "John Smith")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        let loader = ParticipantLoader(
            contactsResolver: MockContactsResolving(contactMap: [:]),
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let withHeader = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        context.delete(message)
        try context.save()

        let withoutHeader = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(withHeader.formattedDisplayName, "John Smith")
        XCTAssertEqual(withoutHeader.displayNames, [])
        XCTAssertEqual(withoutHeader.formattedDisplayName, "Unknown Contact")
    }

    func testLoadParticipants_groupOmitsAddressDerivedNamesAndShowsCount() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John & Sarah")
            .build(in: context)

        let john = PersonBuilder()
            .withEmail("john.smith@example.com")
            .withDisplayName("John Smith")
            .build(in: context)
        let sarah = PersonBuilder()
            .withEmail("sarah@example.com")
            .withDisplayName("Sarah Connor")
            .build(in: context)

        addConversationParticipant(person: john, to: conversation)
        addConversationParticipant(person: sarah, to: conversation)
        try context.save()

        let loader = ParticipantLoader(
            contactsResolver: MockContactsResolving(contactMap: [:]),
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let info = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(info.displayNames, ["Sarah Connor"])
        XCTAssertEqual(info.formattedDisplayName, "Sarah Connor +1")
    }

    func testLoadParticipants_keepsAvatarIdentitiesAlignedWhenGroupOmitsFakeNames() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("John & Sarah")
            .build(in: context)

        let john = PersonBuilder()
            .withEmail("john.smith@example.com")
            .withDisplayName("John Smith")
            .build(in: context)
        let sarah = PersonBuilder()
            .withEmail("sarah@example.com")
            .withDisplayName("Sarah Connor")
            .build(in: context)

        addConversationParticipant(person: john, to: conversation)
        addConversationParticipant(person: sarah, to: conversation)
        try context.save()

        let loader = ParticipantLoader(
            contactsResolver: MockContactsResolving(contactMap: [:]),
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { emails in
                emails.map { email in
                    ProfilePhoto(source: .cached, imageData: nil, url: "photo://\(email)")
                }
            },
            rollupDependencyTracker: ParticipantRollupDependencyTracker()
        )

        let info = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: true
        )

        XCTAssertEqual(info.displayNames, ["Sarah Connor"])
        let namesByEmail = Dictionary(uniqueKeysWithValues: zip(info.emails, info.avatarDisplayNames))
        XCTAssertEqual(namesByEmail["john.smith@example.com"], "Unknown Contact")
        XCTAssertEqual(namesByEmail["sarah@example.com"], "Sarah Connor")
        XCTAssertEqual(info.avatarPhotos.count, 2)
        for (index, email) in info.emails.enumerated() {
            XCTAssertEqual(info.avatarPhotos[index]?.url, "photo://\(email)")
        }
        XCTAssertEqual(info.formattedDisplayName, "Sarah Connor +1")
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
            currentUserEmail: "me@example.com",
            includePhotos: false
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
            currentUserEmail: "me@example.com",
            includePhotos: false
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
            currentUserEmail: "me@example.com",
            includePhotos: false
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

    func testLoadParticipants_invalidatesCachedRollupWhenContactStoreChanges() async throws {
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
        let contactsResolver = CountingContactsResolving(contactMap: [:])
        let loader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { _ in [] },
            rollupDependencyTracker: dependencyTracker
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

        contactsResolver.setContact(
            ContactMatch(
                displayName: "Address Book Friend",
                email: "friend@example.com",
                imageData: nil,
                contactIdentifier: "contact-friend"
            ),
            for: "friend@example.com"
        )
        NotificationCenter.default.post(name: .CNContactStoreDidChange, object: nil)

        let updated = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: false
        )

        XCTAssertEqual(initial.formattedDisplayName, "Header Friend")
        XCTAssertEqual(updated.formattedDisplayName, "Address Book Friend")
        XCTAssertEqual(contactsResolver.lookupCount, 2)
    }

    func testLoadParticipants_doesNotRetainRawPhotoPayloadsInRollupCache() async throws {
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
        let payload = Data(repeating: 0xAB, count: 1_024)
        let loader = ParticipantLoader(
            contactsResolver: contactsResolver,
            prefetchDisplayNames: { _ in },
            cachedDisplayNameProvider: { _ in nil },
            photoLoader: { emails in
                photoCounter.increment()
                return emails.map { _ in
                    ProfilePhoto(source: .contacts, imageData: payload, url: nil)
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
            fallbackDisplayName: conversation.displayName,
            includePhotos: true
        )
        let second = await loader.loadParticipants(
            from: conversation.objectID,
            in: context,
            currentUserEmail: "me@example.com",
            maxParticipants: 4,
            participantHash: conversation.participantHash,
            fallbackDisplayName: conversation.displayName,
            includePhotos: true
        )

        XCTAssertEqual(first.photos.first?.imageData, payload)
        XCTAssertEqual(second.photos.first?.imageData, payload)
        XCTAssertEqual(photoCounter.count, 2)
        XCTAssertEqual(contactsResolver.lookupCount, 1)
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
    private var contactMap: [String: ContactMatch]
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
        let match = contactMap[normalized] ?? contactMap[email]
        lock.unlock()

        return match
    }

    func prewarm(emails: [String]) async {}

    func setContact(_ match: ContactMatch?, for email: String) {
        let normalized = EmailNormalizer.normalize(email)

        lock.lock()
        if let match {
            contactMap[normalized] = match
        } else {
            contactMap.removeValue(forKey: normalized)
            contactMap.removeValue(forKey: email)
        }
        lock.unlock()
    }
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
