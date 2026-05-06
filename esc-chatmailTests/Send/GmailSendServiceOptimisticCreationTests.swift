import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class GmailSendServiceOptimisticCreationTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var sendService: GmailSendService!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        sendService = GmailSendService(viewContext: coreDataStack.viewContext)
    }

    override func tearDown() {
        coreDataStack?.resetViewContext()
        sendService = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testCreateOptimisticMessage_newConversationLeavesChangesPendingWithStableIDs() async throws {
        let context = coreDataStack.viewContext
        let attachmentBuilder = OutboundAttachmentContextBuilder(viewContext: context)
        let attachment = AttachmentBuilder()
            .withId("local_attachment_1")
            .asImage()
            .queued()
            .withLocalURL("Attachments/photo.jpg")
            .withPreviewURL("Previews/photo.jpg")
            .build(in: context)

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "hello",
            subject: "Subject",
            attachments: try attachmentBuilder.buildSendAttachments(from: [attachment]),
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )

        XCTAssertTrue(context.hasChanges, "Optimistic creation should defer persistence so send navigation is not blocked.")
        let fetched = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertFalse(fetched.objectID.isTemporaryID)

        let conversation = try XCTUnwrap(fetched.conversation)
        XCTAssertFalse(conversation.objectID.isTemporaryID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))

        XCTAssertEqual(fetched.attachmentsArray.compactMap(\.id), ["local_attachment_1"])
    }

    func testCreateOptimisticMessage_persistsMutationRecordBeforeViewContextSave() async throws {
        let context = coreDataStack.viewContext
        let recipient = "durable-record@example.com"

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "pending send",
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail(recipient)])
            )
        )

        XCTAssertTrue(context.hasChanges, "The optimistic message graph should still be pending.")

        coreDataStack.resetViewContext()

        XCTAssertNil(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 1)
    }

    func testCreateOptimisticMessage_rollsBackPendingGraphWhenMutationRecordPersistenceFails() async throws {
        let context = MutationRecordPersistenceFailingContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coreDataStack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        let failingSendService = GmailSendService(viewContext: context)
        let attachment = AttachmentBuilder()
            .withId("local_record_failure_attachment")
            .asImage()
            .queued()
            .withLocalURL("Attachments/record-failure.jpg")
            .withPreviewURL("Previews/record-failure.jpg")
            .build(in: context)
        let attachmentContexts = try OutboundAttachmentContextBuilder(viewContext: context)
            .buildSendAttachments(from: [attachment])
        context.failMutationRecordPersistence = false
        let recipient = "record-failure@example.com"

        do {
            _ = try await failingSendService.createOptimisticMessage(
                to: [recipient],
                body: "pending send",
                attachments: attachmentContexts,
                optimisticConversation: .participantHash(
                    calculateParticipantHash(from: [normalizedEmail(recipient)])
                )
            )
            XCTFail("Expected optimistic creation to fail")
        } catch let error as GmailSendService.SendError {
            guard case .optimisticCreationFailed = error else {
                return XCTFail("Expected optimisticCreationFailed but got \(error)")
            }
        }

        context.failMutationRecordPersistence = false
        XCTAssertEqual(try messageCount(in: context), 0)
        XCTAssertEqual(try conversationCount(in: context), 0)
        XCTAssertEqual(try attachmentCount(in: context), 0)
        XCTAssertEqual(try optimisticMutationRecordCount(in: context), 0)
    }

    func testCreateOptimisticMessage_reactivatesArchivedConversationWithoutImmediateSave() async throws {
        let context = coreDataStack.viewContext
        let recipient = "friend@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])

        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Archived")
            .archived()
            .build(in: context)
        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "hello again",
            optimisticConversation: .participantHash(participantHash)
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let conversation = try XCTUnwrap(message.conversation)
        XCTAssertEqual(conversation.objectID, archivedConversation.objectID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))
        XCTAssertNil(conversation.archivedAt)
        XCTAssertTrue(context.hasChanges, "Reactivating the conversation and inserting the optimistic message should remain unsaved until the send flow persists it.")
    }

    func testCreateOptimisticMessage_withOptimisticConversationReferenceReusesExistingConversation() async throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)
        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "anchored reply",
            subject: "Re: Hello",
            threadId: "thread-123",
            optimisticConversation: .existingConversation(ConversationReference(objectID: conversation.objectID))
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(message.conversation?.objectID, conversation.objectID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))
        XCTAssertEqual(message.gmThreadId, "thread-123")
        XCTAssertTrue(context.hasChanges, "Anchored optimistic replies should stay unsaved until the background send path persists them.")
    }

    private func optimisticMutationRecordCount(in context: NSManagedObjectContext) throws -> Int {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func messageCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Message.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func conversationCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Conversation.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }

    private func attachmentCount(in context: NSManagedObjectContext) throws -> Int {
        let request = Attachment.fetchRequest()
        request.includesPendingChanges = true
        return try context.count(for: request)
    }
}

private final class MutationRecordPersistenceFailingContext: NSManagedObjectContext {
    var failMutationRecordPersistence = false

    override var persistentStoreCoordinator: NSPersistentStoreCoordinator? {
        get {
            failMutationRecordPersistence ? nil : super.persistentStoreCoordinator
        }
        set {
            super.persistentStoreCoordinator = newValue
        }
    }

    override func obtainPermanentIDs(for objects: [NSManagedObject]) throws {
        try super.obtainPermanentIDs(for: objects)
        failMutationRecordPersistence = true
    }
}
