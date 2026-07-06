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

    func testResolveConversationObjectID_keepsArchivedThreadArchivedForNonInboxIncomingMessage() async throws {
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

        XCTAssertEqual(objectID, conversation.objectID)
        XCTAssertEqual(conversation.archivedAt, archivedAt)
        XCTAssertTrue(conversation.hidden)
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
        isFromMe: Bool
    ) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "Project"
        headers.from = isFromMe ? "Me <me@example.com>" : "Alice <alice@example.com>"
        headers.to = [
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
            plainTextBody: "Body",
            labelIds: labelIds,
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )
    }
}
