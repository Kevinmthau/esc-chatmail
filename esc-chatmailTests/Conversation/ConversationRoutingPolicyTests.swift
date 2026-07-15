import XCTest
import CoreData
@testable import esc_chatmail

final class ConversationRoutingPolicyTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var policy: ConversationRoutingPolicy!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
        policy = ConversationRoutingPolicy()
    }

    override func tearDown() {
        policy = nil
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testShouldReactivateArchivedConversation_forInboxOrSentMessages() {
        XCTAssertTrue(policy.shouldReactivateArchivedConversation(labelIDs: ["INBOX"], isFromMe: false))
        XCTAssertTrue(policy.shouldReactivateArchivedConversation(labelIDs: ["SENT"], isFromMe: false))
        XCTAssertTrue(policy.shouldReactivateArchivedConversation(labelIDs: [], isFromMe: true))
        XCTAssertFalse(policy.shouldReactivateArchivedConversation(labelIDs: [], isFromMe: false))
    }

    func testSelectParticipantHashConversation_prefersActiveConversation() {
        let participantHash = "same-participant-hash"
        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .archived()
            .setHidden()
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .build(in: context)
        let activeConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .visible()
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .build(in: context)

        let selected = policy.selectParticipantHashConversation(
            from: [archivedConversation, activeConversation],
            reactivateArchivedIfNeeded: true
        )

        XCTAssertEqual(selected?.objectID, activeConversation.objectID)
    }

    func testSelectParticipantHashConversation_ignoresArchivedConversationWhenReactivationIsNotAllowed() {
        let archivedConversation = ConversationBuilder()
            .withParticipantHash("participant-hash")
            .archived()
            .setHidden()
            .build(in: context)

        let selected = policy.selectParticipantHashConversation(
            from: [archivedConversation],
            reactivateArchivedIfNeeded: false
        )

        XCTAssertNil(selected)
    }
}

final class MessageConversationRouterTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var router: MessageConversationRouter!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
        router = MessageConversationRouter()
    }

    override func tearDown() {
        router = nil
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testResolveConversationObjectID_reactivatesArchivedThreadForSentMessage() async throws {
        let archivedAt = Date(timeIntervalSince1970: 100)
        let conversation = makeArchivedConversation(participant: "alice@example.com", archivedAt: archivedAt)
        MessageBuilder()
            .withId("existing-thread-message")
            .withThreadId("thread-sent-reactivation")
            .withSubject("Project")
            .inConversation(conversation)
            .build(in: context)
        try testStack.saveViewContext()

        let processedMessage = makeProcessedMessage(
            id: "sent-reply",
            threadId: "thread-sent-reactivation",
            labelIds: ["SENT"],
            isFromMe: true
        )

        let objectID = try await router.resolveConversationObjectID(
            for: processedMessage,
            myAliases: ["me@example.com"],
            in: context
        )

        XCTAssertEqual(objectID, conversation.objectID)
        XCTAssertNil(conversation.archivedAt)
        XCTAssertFalse(conversation.hidden)
    }

    func testResolveConversationObjectID_keepsArchivedConversationArchivedAndCreatesNewEpochForNonInboxIncomingMessage() async throws {
        let archivedAt = Date(timeIntervalSince1970: 100)
        let conversation = makeArchivedConversation(participant: "alice@example.com", archivedAt: archivedAt)
        MessageBuilder()
            .withId("existing-archived-thread-message")
            .withThreadId("thread-archived-incoming")
            .withSubject("Project")
            .inConversation(conversation)
            .build(in: context)
        try testStack.saveViewContext()

        let processedMessage = makeProcessedMessage(
            id: "archived-incoming",
            threadId: "thread-archived-incoming",
            labelIds: [],
            isFromMe: false
        )

        let objectID = try await router.resolveConversationObjectID(
            for: processedMessage,
            myAliases: ["me@example.com"],
            in: context
        )

        XCTAssertNotEqual(objectID, conversation.objectID)
        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2)
        XCTAssertEqual(conversation.archivedAt, archivedAt)
        XCTAssertTrue(conversation.hidden)

        let newConversation = try XCTUnwrap(context.existingObject(with: objectID) as? Conversation)
        XCTAssertEqual(newConversation.participantHash, conversation.participantHash)
    }

    func testResolveConversationObjectID_createsNewParticipantEpochWhenOnlyArchivedMatchDoesNotReactivate() async throws {
        let archivedConversation = makeArchivedConversation(
            participant: "alice@example.com",
            archivedAt: Date(timeIntervalSince1970: 100)
        )
        try testStack.saveViewContext()

        let processedMessage = makeProcessedMessage(
            id: "new-non-inbox-message",
            threadId: "",
            labelIds: [],
            isFromMe: false
        )

        let objectID = try await router.resolveConversationObjectID(
            for: processedMessage,
            myAliases: ["me@example.com"],
            in: context
        )

        XCTAssertNotEqual(objectID, archivedConversation.objectID)
        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2)

        let newConversation = try XCTUnwrap(context.existingObject(with: objectID) as? Conversation)
        XCTAssertNil(newConversation.archivedAt)
        XCTAssertFalse(newConversation.hidden)
        XCTAssertEqual(newConversation.participantHash, archivedConversation.participantHash)
    }

    func testResolveConversationObjectID_sameGmThreadIdDifferentParticipantSets_createsSeparateConversations() async throws {
        let aliceHash = calculateParticipantHash(from: ["alice@example.com"])
        let aliceConversation = ConversationBuilder()
            .withParticipantHash(aliceHash)
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("existing-alice-message")
            .withThreadId("thread-shared")
            .withSubject("Project")
            .inConversation(aliceConversation)
            .build(in: context)
        try testStack.saveViewContext()

        let processedMessage = makeProcessedMessage(
            id: "alice-adds-bob",
            threadId: "thread-shared",
            labelIds: ["INBOX"],
            isFromMe: false,
            to: [
                EmailAddress(email: "me@example.com", displayName: nil),
                EmailAddress(email: "bob@example.com", displayName: nil)
            ]
        )

        let objectID = try await router.resolveConversationObjectID(
            for: processedMessage,
            myAliases: ["me@example.com"],
            in: context
        )

        XCTAssertNotEqual(objectID, aliceConversation.objectID)
        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2)

        let groupConversation = try XCTUnwrap(context.existingObject(with: objectID) as? Conversation)
        XCTAssertEqual(
            groupConversation.participantHash,
            calculateParticipantHash(from: ["alice@example.com", "bob@example.com"])
        )
        XCTAssertEqual(aliceConversation.participantHash, aliceHash)
    }

    func testResolveConversationObjectID_sameParticipantSetAcrossDifferentGmThreadIds_reusesConversation() async throws {
        let firstObjectID = try await router.resolveConversationObjectID(
            for: makeProcessedMessage(
                id: "alice-thread-one",
                threadId: "thread-one",
                labelIds: ["INBOX"],
                isFromMe: false
            ),
            myAliases: ["me@example.com"],
            in: context
        )

        let secondObjectID = try await router.resolveConversationObjectID(
            for: makeProcessedMessage(
                id: "alice-thread-two",
                threadId: "thread-two",
                labelIds: ["INBOX"],
                isFromMe: false
            ),
            myAliases: ["me@example.com"],
            in: context
        )

        XCTAssertEqual(firstObjectID, secondObjectID)
        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 1)
    }

    func testResolveConversationObjectID_forwardedMessageWithSameParticipantSet_routesToSameConversation() async throws {
        let aliceConversation = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: ["alice@example.com"]))
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("existing-alice-message")
            .withThreadId("thread-forwarded")
            .withSubject("Project")
            .inConversation(aliceConversation)
            .build(in: context)
        try testStack.saveViewContext()

        let forwardedMessage = makeProcessedMessage(
            id: "forwarded-from-alice",
            threadId: "thread-forwarded",
            labelIds: ["INBOX"],
            isFromMe: false,
            subject: "Fwd: something",
            plainTextBody: "---------- Forwarded message ---------\nFrom: Carol <carol@example.com>\nOriginal content"
        )

        let objectID = try await router.resolveConversationObjectID(
            for: forwardedMessage,
            myAliases: ["me@example.com"],
            in: context
        )

        XCTAssertEqual(objectID, aliceConversation.objectID)
        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 1)
    }

    func testResolveConversationObjectID_selfOnlyMessage_routesToDeterministicSelfConversation() async throws {
        let myAliases: Set<String> = ["me@example.com", "alias@example.com"]

        let firstObjectID = try await router.resolveConversationObjectID(
            for: makeProcessedMessage(
                id: "note-to-self-one",
                threadId: "thread-self-one",
                labelIds: ["SENT"],
                isFromMe: true,
                from: "Me <me@example.com>",
                to: [EmailAddress(email: "me@example.com", displayName: nil)]
            ),
            myAliases: myAliases,
            in: context
        )

        let secondObjectID = try await router.resolveConversationObjectID(
            for: makeProcessedMessage(
                id: "note-to-self-two",
                threadId: "thread-self-two",
                labelIds: ["SENT"],
                isFromMe: true,
                from: "Me <me@example.com>",
                to: [EmailAddress(email: "me@example.com", displayName: nil)]
            ),
            myAliases: myAliases,
            in: context
        )

        XCTAssertEqual(firstObjectID, secondObjectID)
        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 1)

        let selfConversation = try XCTUnwrap(context.existingObject(with: firstObjectID) as? Conversation)
        XCTAssertEqual(selfConversation.participantHash, calculateParticipantHash(from: ["alias@example.com"]))
    }

    func testResolveConversationObjectID_legacyConversationWithNilParticipantHash_isNotReusedOrBackfilled() async throws {
        let legacyConversation = ConversationBuilder()
            .visible()
            .build(in: context)
        MessageBuilder()
            .withId("legacy-thread-message")
            .withThreadId("thread-legacy")
            .withSubject("Project")
            .inConversation(legacyConversation)
            .build(in: context)
        try testStack.saveViewContext()

        let processedMessage = makeProcessedMessage(
            id: "incoming-on-legacy-thread",
            threadId: "thread-legacy",
            labelIds: ["INBOX"],
            isFromMe: false
        )

        let objectID = try await router.resolveConversationObjectID(
            for: processedMessage,
            myAliases: ["me@example.com"],
            in: context
        )

        XCTAssertNotEqual(objectID, legacyConversation.objectID)
        let conversationCount = try context.count(for: Conversation.fetchRequest())
        XCTAssertEqual(conversationCount, 2)
        XCTAssertNil(legacyConversation.participantHash)

        let newConversation = try XCTUnwrap(context.existingObject(with: objectID) as? Conversation)
        XCTAssertEqual(newConversation.participantHash, calculateParticipantHash(from: ["alice@example.com"]))
    }

    private func makeArchivedConversation(participant: String, archivedAt: Date) -> Conversation {
        ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [participant]))
            .archivedOn(archivedAt)
            .setHidden()
            .hasInboxMessages(false)
            .build(in: context)
    }

    private func makeProcessedMessage(
        id: String,
        threadId: String,
        labelIds: [String],
        isFromMe: Bool,
        subject: String = "Project",
        from: String? = nil,
        to: [EmailAddress]? = nil,
        plainTextBody: String = "Body"
    ) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = subject
        headers.from = from ?? (isFromMe ? "Me <me@example.com>" : "Alice <alice@example.com>")
        headers.to = to ?? [
            EmailAddress(
                email: isFromMe ? "alice@example.com" : "me@example.com",
                displayName: nil
            )
        ]
        headers.isFromMe = isFromMe

        return ProcessedMessage(
            id: id,
            gmThreadId: threadId,
            snippet: "Snippet",
            cleanedSnippet: "Snippet",
            internalDate: Date(),
            headers: headers,
            htmlBody: nil,
            plainTextBody: plainTextBody,
            labelIds: labelIds,
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )
    }
}
